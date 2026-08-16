# Architecture overview (last updated: 2026-08-15)

How the implemented modules map to the architecture spec. The specs
(`../codelead-*.md`) remain the target-state source of truth; this
note is the "how it works today" map.

## Contexts (data)

| Module | Owns |
|---|---|
| `CodeLead.Accounts` | organization singleton, users (no auth flows yet) |
| `CodeLead.Projects` | projects, repositories, encrypted env store |
| `CodeLead.Agents` | providers (encrypted config), agent personas, eligibility rules, default reviewers, provider env for harnesses |
| `CodeLead.Workflow` | the declarative workflow definition (spec §4.1) — stages with a `stage_type`, transitions with trigger/context/worktree policies. Pure data; one built-in, named by `tasks.workflow_key` |
| `CodeLead.Tasks` | the task state machine (spec §4) driven by that definition, task steps, task reviewers, attention, board queries |
| `CodeLead.Planning` | the planning surface (`planning_messages`): `llm_api` spec refinement and the `acp` repo-aware survey |
| `CodeLead.AdvisoryRun` | one read-only agent run — reviewers and planning surveys share it; raises attention on escalations, owns its deadline |
| `CodeLead.AgentFeed` | the executor transcript (`agent_events`) behind the Agent tab — see [ADR-0002](adr/0002-persist-agent-transcript.md); **not in the architecture spec's data model**, a deliberate addition |
| `CodeLead.Reviews` | review cycles, fan-out, advisory verdicts (over `CodeLead.AdvisoryRun`) |
| `CodeLead.Costs` | agent_runs, daily_metrics rollup (Oban), pricing, budget gate |

## Behaviours (extension points, one MVP impl each)

| Behaviour | MVP impl | Later |
|---|---|---|
| `CodeLead.AgentDriver` | `Acp` (harness over ACP, ADR-0001), `LlmApi` (one completion) | — (driver-independent of executor) |
| `CodeLead.Executor` | `LocalSubprocess` (default) and `DockerContainer` (per-task opt-in, `Executor.for_task/1` on `tasks.execution_env`); `spawn/3` runs the agent *inside* the provisioned context ([ADR-0003](adr/0003-container-execution-model.md), [ADR-0004](adr/0004-container-executor-iteration-two.md)) | `:devcontainer`/`:dockerfile` env kinds |
| `CodeLead.Scheduler` | `PassThrough` — an ordered `CodeLead.Scheduler.Gate` list (schedule → budget → capacity) | a `WindowGate` in the same list |
| `CodeLead.PreviewGateway` | `PathProxy` — the Review tab frames `/preview/:task_id/` and `CodeLeadWeb.PreviewProxyController` reverse-proxies it (HTTP + websockets) to the task's dev server, resolved per execution env ([ADR-0008](adr/0008-preview-and-terminal.md)) | `SubdomainProxy` (per-task subdomains) |

## Runtime (processes)

- `CodeLead.Runtime` — human-facing run control (start/cancel/retry,
  request_changes, send_back_to_planning, approve, permissions, queue
  kick). The LiveViews call these. Each column move goes through
  `advance/3`, which resolves the edge in the task's `CodeLead.Workflow`
  and runs the target stage's effects around the write.
- `CodeLead.Runtime.StageEffects` — the only stage-type → behaviour
  map: `prepare/2` before the state is written (finalization, which can
  veto) and `on_enter/3` after it (dispatch, reviewer fan-out, and the
  post-finalize teardown a finalize outcome asks for). It also owns
  `discard_context/1`, the one teardown both the `:discard` worktree
  policy and that outcome go through.
- `CodeLead.Runtime.TaskRunner` — one GenServer per active run
  (DynamicSupervisor + Registry), consumes driver events, persists the
  transcript through `CodeLead.AgentFeed` (which broadcasts
  `{:agent_feed, task_id, row}`), broadcasts task events on
  `task:<id>`, records usage/audit. It is the single writer of a task's
  transcript, so tool-call correlation and the open message row live in
  its state rather than in SQL. Board notifications (`project:<id>` →
  `:board_changed`) come from `CodeLead.Tasks` on every task write.
- `CodeLead.Acp.Connection` — Port bridge per ACP subprocess.
- `CodeLead.Executor.DockerContainer.Bootstrap` — one-shot boot task:
  stages the compiled harness binary onto the workspace volume and
  reaps labeled orphan task containers; no-ops (with a log) when docker
  or the staging source is absent.
- `CodeLead.TaskSupervisor` — Task.Supervisor for review fan-out,
  LlmApi calls, terminal commands, queue kicks.
- `CodeLead.Terminal.Session` — one GenServer per task with an open
  Developer-terminal shell (DynamicSupervisor + Registry under
  `CodeLead.Terminal`): owns the shell Port so the session survives
  page refreshes, keeps a bounded scrollback, broadcasts on
  `terminal:<id>`, idles out viewer-less (ADR-0008).
- `CodeLead.Finalizer` — the system executor behind Approve → Done,
  dispatched on the task's target and its resolved finalize mode (PR,
  merge, squash, artifact, commit-to-path).
- `CodeLead.Vault` — Cloak encryption (provider config, project env).
- `CodeLead.Agents.SubscriptionUsageCache` — polls every
  `:anthropic_subscription` provider's rate-limit windows on a timer,
  reading Anthropic's undocumented `anthropic-ratelimit-unified-*`
  response headers (no supported API exists for this); feeds the
  sidebar's rate-limit tile via `NavContext`. Best-effort by design — see
  `docs/navigation.md`.
- Oban — `rollups` queue (nightly `Costs.RollupWorker` cron) and
  `dispatch` queue (`Runtime.ScheduledDispatchWorker` wake-ups for
  scheduled runs).

## Support

`CodeLead.Git` (CLI porcelain), `CodeLead.Workspace` (path layout),
`CodeLead.Acp.JsonRpc` (framing). See the per-area design notes in
this directory for details.
