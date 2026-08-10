# Agent drivers (last updated: 2026-08-10, ACP driver added)

`CodeLead.AgentDriver` is the behaviour every way of running an agent
implements. Callbacks: `start_run(task, agent, context, prompt)`,
`send_message(handle, msg)`, `cancel(handle)`.

## Event contract

The `start_run/4` caller receives `{:agent_event, handle, event}`
messages; exactly one terminal `{:result, %{status:, content:, usage:,
session_id:}}` per run. Other events: `{:message_chunk, text}`,
`{:tool_call, map}`, `{:permission_request, map}` (escalations only —
in-sandbox requests are auto-granted by the driver), `{:question,
text}`. Task state is derived from these events, never from agent
self-report. Usage reports tokens with `cost_cents: nil` unless the
backend reports money; `CodeLead.Costs.with_cost/2` prices it.

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
    (`%{claude_code: [...], codex: [...]}`); provider credentials are
    injected as env vars (`Agents.provider_env/1`).
  - Tested against `test/support/fake_acp_agent.exs`, a scripted
    stdio agent with happy/writes_file/permission/terminal/crash/
    resume scenarios.

`CodeLead.AgentDriver.impl/1` resolves the module from
`agent.driver`.
