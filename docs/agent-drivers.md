# Agent drivers (last updated: 2026-08-10)

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
- **`Acp`** — coding harness over the Agent Client Protocol (Step 9;
  not yet implemented).

`CodeLead.AgentDriver.impl/1` resolves the module from
`agent.driver`.
