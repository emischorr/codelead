# Agent drivers (last updated: 2026-08-11, tool-call detail)

`CodeLead.AgentDriver` is the behaviour every way of running an agent
implements. Callbacks: `start_run(task, agent, context, prompt)`,
`send_message(handle, msg)`, `cancel(handle)`.

## Event contract

The `start_run/4` caller receives `{:agent_event, handle, event}`
messages; exactly one terminal `{:result, %{status:, content:, usage:,
session_id:}}` per run. Other events: `{:message_chunk, text}`,
`{:tool_call, map}`, `{:permission_request, map}` (escalations only —
in-sandbox requests are auto-granted by the driver), `{:question,
text}`, `{:usage, snapshot}`. Task state is derived from these events,
never from agent self-report.

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
  - **Permission policy:** in-sandbox requests are auto-granted;
    requests whose tool-call locations leave the context path surface
    as `{:permission_request, %{id:, detail:}}` and wait for
    `Acp.answer_permission/3`.
  - **Client capabilities served:** `fs/read_text_file`,
    `fs/write_text_file` (sandbox-checked), `terminal/*` (command runs
    to completion under `CodeLead.TaskSupervisor`; output is returned
    once finished).
  - Harness launch commands come from the `:harnesses` config map
    (`%{claude_code: ["claude-agent-acp"], codex: ["codex", "acp"]}`),
    resolved against the server process's own PATH; provider credentials
    are injected as env vars (`Agents.provider_env/1`). The Docker image
    bundles the Claude harness — see `docs/configuration.md`.
  - Tested against `test/support/fake_acp_agent.exs`, a scripted
    stdio agent with happy/tool_updates/writes_file/permission/
    terminal/crash/resume scenarios.

`CodeLead.AgentDriver.impl/1` resolves the module from
`agent.driver`.

## Preflight

`preflight(agent)` answers "could this agent be launched at all?"
`TaskRunner` calls it *before* `Executor.provision/1`, so a harness that
isn't installed fails the run without first cloning a repository.

- `Acp` resolves the `:harnesses` argv and asks the executor whether it
  can run it (`Executor.available?/1`, `System.find_executable/1` under
  `LocalSubprocess`). Returns `{:error, {:unknown_harness, harness}}` or
  `{:error, {:executable_not_found, binary}}`.
- `LlmApi` returns `:ok` — nothing is launched; a bad credential only
  shows up in the provider's response.

`TaskRunner.dispatch_error/1` turns these (and provisioning failures)
into the sentence the operator reads in the task timeline.
