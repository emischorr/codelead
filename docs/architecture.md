# Architecture overview (last updated: 2026-08-11)

How the implemented modules map to the architecture spec. The specs
(`../codelead-*.md`) remain the target-state source of truth; this
note is the "how it works today" map.

## Contexts (data)

| Module | Owns |
|---|---|
| `CodeLead.Accounts` | organization singleton, users (no auth flows yet) |
| `CodeLead.Projects` | projects, repositories, encrypted env store |
| `CodeLead.Agents` | providers (encrypted config), agent personas, eligibility rules, default reviewers, provider env for harnesses |
| `CodeLead.Tasks` | the task state machine (spec §4), task steps, task reviewers, attention, board queries |
| `CodeLead.Planning` | planning-assistant chat (`planning_messages`) |
| `CodeLead.AgentFeed` | the executor transcript (`agent_events`) behind the Agent tab — see [ADR-0002](adr/0002-persist-agent-transcript.md); **not in the architecture spec's data model**, a deliberate addition |
| `CodeLead.Reviews` | review cycles, fan-out, advisory verdicts |
| `CodeLead.Costs` | agent_runs, daily_metrics rollup (Oban), pricing, budget gate |

## Behaviours (extension points, one MVP impl each)

| Behaviour | MVP impl | Later |
|---|---|---|
| `CodeLead.AgentDriver` | `Acp` (harness over ACP, ADR-0001), `LlmApi` (one completion) | — (driver-independent of executor) |
| `CodeLead.Executor` | `LocalSubprocess` (worktree/folder + Ports) | `DockerContainer` |
| `CodeLead.Scheduler` | `PassThrough` (budget + capacity) | `Windowed` |

## Runtime (processes)

- `CodeLead.Runtime` — human-facing run control (start/cancel/retry,
  request_changes, send_back_to_planning, approve, permissions, queue
  kick). The LiveViews call these.
- `CodeLead.Runtime.TaskRunner` — one GenServer per active run
  (DynamicSupervisor + Registry), consumes driver events, persists the
  transcript through `CodeLead.AgentFeed` (which broadcasts
  `{:agent_feed, task_id, row}`), broadcasts task events on
  `task:<id>`, records usage/audit. It is the single writer of a task's
  transcript, so tool-call correlation and the open message row live in
  its state rather than in SQL. Board notifications (`project:<id>` →
  `:board_changed`) come from `CodeLead.Tasks` on every task write.
- `CodeLead.Acp.Connection` — Port bridge per ACP subprocess.
- `CodeLead.TaskSupervisor` — Task.Supervisor for review fan-out,
  LlmApi calls, terminal commands, queue kicks.
- `CodeLead.Finalizer` — the system executor behind Approve → Done.
- `CodeLead.Vault` — Cloak encryption (provider config, project env).
- Oban — `rollups` queue, nightly `Costs.RollupWorker` cron.

## Support

`CodeLead.Git` (CLI porcelain), `CodeLead.Workspace` (path layout),
`CodeLead.Acp.JsonRpc` (framing). See the per-area design notes in
this directory for details.
