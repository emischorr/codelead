# Agent drivers (last updated: 2026-08-15, preflight/2)

`CodeLead.AgentDriver` is the behaviour every way of running an agent
implements. Callbacks: `start_run(task, agent, context, prompt)`,
`send_message(handle, msg)`, `cancel(handle)`.

## Event contract

The `start_run/4` caller receives `{:agent_event, handle, event}`
messages; exactly one terminal `{:result, %{status:, content:, usage:,
session_id:}}` per run. Other events: `{:message_chunk, text}`,
`{:tool_call, map}`, `{:permission_request, map}` (escalations only —
in-sandbox requests are auto-granted by the driver), `{:question, map}`,
`{:usage, snapshot}`. Task state is derived from these events, never
from agent self-report.

`{:question, %{id:, detail:, fields:, tool_call_id:}}` is the agent
asking the human something, and the agent is **blocked** on it: the
request stays open on the wire until `Acp.answer_question/3`. `detail`
is the prompt; `fields` is already normalized into selects,
multi-selects and free-text inputs, so no consumer parses JSON Schema.

`usage` reports the token split — `prompt_tokens`,
`completion_tokens`, `cached_read_tokens`, `cached_write_tokens`,
`reasoning_tokens`, `total_tokens` — plus `cost_cents`, which is `nil`
unless the backend reported money. ACP harnesses generally do, and
their figure wins: `CodeLead.Costs.with_cost/2` only prices what the
backend left unpriced, and its rate table has no cache rates.

`{:usage, %{cost_cents:, context_used:, context_size:}}` is advisory
and may arrive any number of times or not at all — it drives the live
cost readout during a run, and is the fallback usage for a run that
dies before its terminal result. `context_used`/`context_size` are
context-window occupancy, not tokens billed. See
[`cost-tracking.md`](cost-tracking.md) for where these numbers come
from on the wire.

`{:tool_call, %{id:, title:, kind:, status:, locations:, raw_input:}}`
is emitted **once per status change of the same call** (ACP's
`tool_call` and `tool_call_update` share this event), and after the
first only `id` and `status` are reliably non-nil. Consumers correlate
by `id` and merge non-nil fields — `Runtime.TaskRunner` does this in
its own state, keyed per run, since `toolCallId` is only unique within
an ACP session. `raw_input` is unbounded and untrusted (a command line
can carry a project env secret), so it reaches the transcript as a map
of its string fields only — each redacted with `Git.redact/1` and *then*
truncated (a token cut in half no longer matches the patterns). Keeping
it field by field is what lets the Agent tab render a shell call as
"description: command"; dropping the non-strings drops timeouts and
other machinery, and bounds the stored payload. Deliberately **not**
passed through: the tool's `content` (whole file bodies / command
output — needs its own payload budget) and `agent_thought_chunk`
(dropped by the driver; a two-line clause when we want it).

## Implementations

- **`LlmApi`** — one completion call via Req to the agent's provider
  (Anthropic `/v1/messages`, OpenAI chat completions, Ollama
  `/api/chat`). Runs under `CodeLead.TaskSupervisor`; the whole
  completion arrives as one chunk + result. `send_message/2` is
  unsupported. `complete/4` is exposed for synchronous multi-turn use
  (planning chat). Tests stub the network with `Req.Test` via the
  `:llm_api_req_options` config.
- **`Acp`** — a coding harness (Claude Code / Codex) as an ACP
  subprocess (see ADR-0001). One GenServer per run owns an
  `Acp.Connection` (Erlang Port, ndjson JSON-RPC, id correlation),
  does initialize → `session/new` (or `session/load` when the task has
  a session and the harness advertises `loadSession`; failed loads
  fall back to a fresh session) → `session/prompt`, and translates
  `session/update` notifications into normalized events. Extra event:
  `{:session_started, id}` for the runner to persist.
  - **Session/load replay is dropped, not forwarded.** Per the ACP
    spec, `session/load` replays the entire prior conversation as
    `session/update` notifications before it responds — the human
    already has that history in the persisted transcript from earlier
    runs (see `docs/task-workflow.md`), so the driver ignores every
    `session/update` that arrives while still in the `:loading_session`
    stage. Only updates from the `session/prompt` turn that follows are
    translated into events.
  - **Permission policy:** in-sandbox requests are auto-granted. A
    request whose tool-call locations all sit under the context path
    passes regardless of kind; a location-less request passes only for
    known-inert kinds plus `execute` (shell is bounded by the sandbox
    cwd and the scrubbed env). Everything else — a location leaving the
    context path, a destructive kind (`delete`/`move`) without
    locations, an unrecognized or missing kind, or a malformed
    location — surfaces as `{:permission_request, %{id:, detail:}}`
    and waits for `Acp.answer_permission/3`. A human Deny with no
    reject-kind option answers `cancelled`, never a fallback option.
    `terminal/create` is confined the same way: an out-of-sandbox
    `cwd` is refused with a JSON-RPC error.
  - **Asking the human (elicitation):** the client advertises
    `clientCapabilities.elicitation.form`, and that advertisement is
    what makes the harness offer its ask-the-human tool at all —
    Claude Code's adapter puts `AskUserQuestion` in `disallowedTools`
    unless the capability is present, which is why an agent without it
    can only write the question as prose and end its turn. An incoming
    `elicitation/create` is normalized by `CodeLead.Acp.Elicitation`
    and surfaced as `{:question, ...}`; the request is left unanswered,
    which holds the prompt turn open with **no timeout** — waiting for
    the human is the point, and cancelling the run is the escape.
    `Acp.answer_question/3` replies `accept`/`decline`/`cancel` and
    returns the content the agent actually received.

    The capability is withheld for a **read-only context**, so advisory
    runs (reviewers, planning surveys) never get the tool: they are
    blocking calls outside the run registry, so a question there could
    only hang until their own deadline.

    Three agent-side flows ride on the one capability —
    `AskUserQuestion`, elicitations forwarded from an MCP server, and
    the harness's refusal-fallback consent prompt. All three arrive as
    the same normalized field list. Note that `properties` decodes to a
    plain map, so field order is reconstructed by sorting keys
    naturally; a generic MCP form therefore renders in key order rather
    than author order.
  - **Client capabilities served:** `fs/read_text_file`,
    `fs/write_text_file` (sandbox-checked), `terminal/*` (command runs
    to completion under `CodeLead.TaskSupervisor`; output is returned
    once finished), `elicitation/create` (form mode only — a `url`-mode
    request is declined, as is one whose schema yields no fields).
  - Harness launch commands come from the `:harnesses` config map
    (`%{claude_code: ["claude-agent-acp"], codex: ["codex", "acp"]}`),
    resolved against the server process's own PATH; provider credentials
    are injected as env vars (`Agents.provider_env/1`). The Docker image
    bundles the Claude harness — see `docs/configuration.md`.
  - Local subprocesses (harness ports and `terminal/*` commands alike)
    inherit the server's environment, so `CodeLead.Executor.EnvScrub`
    strips CodeLead-internal vars (`WORKSPACE_ROOT`, `DATABASE_URL`,
    secrets, container/harness config) before spawning; explicit
    project/provider env always passes through and wins over the scrub
    on a name collision. Container execution is unaffected — sibling
    containers only ever get explicit `-e` env.
  - Tested against `test/support/fake_acp_agent.exs`, a scripted
    stdio agent with happy/tool_updates/writes_file/permission/
    elicitation/terminal/crash/resume scenarios. The `elicitation`
    scenario mirrors the real adapter's gate — it only asks when the
    client advertised the capability — so the read-only suppression is
    covered without a real harness.

`CodeLead.AgentDriver.impl/1` resolves the module from
`agent.driver`.

## Preflight

`preflight(agent, executor)` answers "could this agent be launched at
all?" The caller resolves and passes the executor module — `TaskRunner`
passes `Executor.for_task(task)`, `AdvisoryRun` the context's own
executor (surveys of a container task still run locally) — and calls it
*before* `provision/1`, so a harness that isn't installed fails the run
without first cloning a repository.

- `Acp` resolves the `:harnesses` argv and asks that executor whether
  it can run it (`available?/1`). "Available" means runnable *inside
  the execution environment* ([ADR-0003](adr/0003-container-execution-model.md)):
  `System.find_executable/1` under `LocalSubprocess`; under
  `Devcontainer`, the docker and devcontainer CLIs resolve and the staged harness
  binary exists (returning `{:error, {:harness_not_staged, path}}` or
  `{:error, {:container_command_unsupported, cmd}}` — only the Claude
  Code harness runs in containers). Local errors stay
  `{:error, {:unknown_harness, harness}}` and
  `{:error, {:executable_not_found, binary}}`. The driver's host-side
  `fs/*` and `terminal/*` handling stays valid only because host and
  context see the workspace at the same paths.
- `LlmApi` returns `:ok` — nothing is launched; a bad credential only
  shows up in the provider's response.

`TaskRunner.dispatch_error/1` turns these (and provisioning failures)
into the sentence the operator reads in the task timeline. For the git
half it delegates to `Git.remote_failure/4`, which
`CodeLeadWeb.FlashMessages.finalize_error/1` also uses — so a credential
refused at clone time and one refused at push time read the same way.
