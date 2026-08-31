# Architecture overview (last updated: 2026-08-31, run-kind live-run registry)

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
| `CodeLead.Executor` | `LocalSubprocess` (default) and `Devcontainer` (per-task opt-in, `Executor.for_task/1` on `tasks.execution_env`; provisions via the devcontainer CLI, execs via docker); `spawn/3` runs the agent *inside* the provisioned context ([ADR-0003](adr/0003-container-execution-model.md), [ADR-0009](adr/0009-devcontainer-execution.md)) | container execution for `:folder` targets |
| `CodeLead.Scheduler` | `PassThrough` — an ordered `CodeLead.Scheduler.Gate` list (schedule → budget → capacity) | a `WindowGate` in the same list |
| `CodeLead.PreviewGateway` | `PathProxy` (default: previews open in a new tab at `/preview/:task_id/`, reverse-proxied by `CodeLeadWeb.PreviewProxyController`) and `SubdomainProxy` (opt-in via `PREVIEW_DOMAIN`: per-task origins `task-<id>.<domain>`, host-matched in `Endpoint.call/2` → `CodeLeadWeb.PreviewHost`) — exactly one active per instance; both share the `PreviewProxy.Forwarder` plumbing (HTTP + websockets) and `PreviewGateway.Upstream` resolution: loopback for local tasks, a relay sidecar's published port for container tasks ([ADR-0008](adr/0008-preview-and-terminal.md), [ADR-0009](adr/0009-devcontainer-execution.md), [ADR-0011](adr/0011-new-tab-preview-and-subdomain-gateway.md)) | `ExternalPreview` (branch-deploy pipelines, see `ROADMAP.md`) |

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
- `CodeLead.Runtime.LiveRuns` — the live-process truth for every agent
  run, over the one `CodeLead.Runtime.Registry` (`keys: :unique`,
  node-local — a restart empties it, honestly). Keys carry the run
  *kind*: `{task_id, :execute}` (the runner), `{task_id, :plan}` (the
  survey), `{task_id, :review, agent_id}` (one per reviewer); key
  uniqueness is the concurrency rule, and the executor-only views
  (`executor_count/0` for the capacity gate, `executor_task_ids/0` for
  the stalled-run check and container reaper) filter by kind.
  Advisory runs self-register as their first act and are stopped
  through `cancel_advisory/1` (ADR-0015).
- `CodeLead.Runtime.TaskRunner` — one GenServer per active run
  (DynamicSupervisor + the registry above), consumes driver events,
  persists the transcript through `CodeLead.AgentFeed` (which
  broadcasts `{:agent_feed, task_id, row}`), broadcasts task events on
  `task:<id>`, records usage/audit. It is the single writer of a task's
  transcript, so tool-call correlation and the open message row live in
  its state rather than in SQL. Board notifications (`project:<id>` →
  `:board_changed`) come from `CodeLead.Tasks` on every task write —
  and, writeless, from `Tasks.notify_board_change/1` when live-run
  state changes (survey start/end).
- `CodeLead.Acp.Connection` — Port bridge per ACP subprocess.
- `CodeLead.Executor.Devcontainer.Bootstrap` — one-shot boot task:
  stages baked harness runtimes onto the workspace and reaps labeled
  orphan task environments (compose-aware) and relays; no-ops (with a
  log) when docker or the staging source is absent.
- `CodeLead.TaskSupervisor` — Task.Supervisor for review fan-out,
  LlmApi calls, terminal commands, queue kicks.
- `CodeLead.Terminal.Session` — one GenServer per task with an open
  Developer-terminal shell (DynamicSupervisor + Registry under
  `CodeLead.Terminal`): owns the shell Port so the session survives
  page refreshes, keeps a bounded scrollback, broadcasts on
  `terminal:<id>`, idles out viewer-less (ADR-0008), and stops the
  shell's process group when the execution context is destroyed or the
  app shuts down — never on request-changes (ADR-0013). Announces its own
  open/close on `org:terminals`, which is how the dashboard counts live
  sessions exactly. Resizes go to the
  PTY device the session recorded at spawn, applied by an `stty` run
  from outside it (ADR-0010). The shell's directory comes from
  `Terminal.context_path/1` — worktree or task folder — so folder-target
  tasks get a terminal too.
- `CodeLead.Preview.Session` — one GenServer per task running the
  repository's `preview_command` (same supervision shape as the
  terminal): owns the server's Port, probes the preview upstream until
  the port answers, broadcasts `{:preview_state, id, status}` on the
  task topic, stops on run entry/context teardown/viewer-less idle/app
  shutdown. A session started with `port_opener: nil` is an *adopted*
  one — it owns no Port and manages a container server that outlived an
  ungraceful exit, re-attached at boot by `Preview.adopt_survivors/0`
  (ADR-0013). Announces its own open/close on `org:previews`. Both
  subsystems own a topic rather than sharing one: per ADR-0013's "no
  shared session abstraction", a coordinator knowing both registries is
  the thing that decision rejected.
- `CodeLead.OsProcess` — pure signalling helpers shared by both
  sessions: closing a Port does not stop the program behind it, and
  port children lead their own process groups, so stopping means
  signalling the group — directly on the host, or through a recorded
  pid file for anything reachable only via `docker exec` (ADR-0013).
- `CodeLead.PreviewGateway.Relay` — per-task socat sidecar
  (`codelead-preview-<id>`) joining the task container's network and
  publishing the preview port on an ephemeral host port (ADR-0009).
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
