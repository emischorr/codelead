# Architecture overview (last updated: 2026-08-10)

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
  kick). The LiveView will call these.
- `CodeLead.Runtime.TaskRunner` — one GenServer per active run
  (DynamicSupervisor + Registry), consumes driver events, broadcasts
  PubSub (`task:<id>`, `project:<id>`), records usage/audit.
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
