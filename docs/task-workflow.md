# Task workflow (last updated: 2026-08-31, background finalization)

Implementation of architecture spec §4 and §4.1 in `CodeLead.Tasks`
(lib/code_lead/tasks.ex). `state` is the Kanban column
(planning/running/review/done/cancelled), `run_state` tracks execution
inside Running (idle/queued/dispatched/executing/failed). `archived_at`
is orthogonal to `state`.

## The definition drives the machine

The column transitions are not hardcoded. `CodeLead.Workflow`
(lib/code_lead/workflow.ex) holds one declarative `%Workflow{}` — the
built-in, keyed `"builtin.default"`, named per task by
`tasks.workflow_key` — and everything else looks moves up in it:

| Module | Role |
|---|---|
| `CodeLead.Workflow` | `built_in/0`, `fetch!/1`, `stage/2`, `fetch_transition/3`, `outgoing/2`. Pure data, no dependencies. |
| `CodeLead.Workflow.Stage` | `key` (the `tasks.state` value), `name`, `position`, `stage_type` (`:plan`/`:execute`/`:review`/`:finalize`/`:custom`, defaulting to the inert `:custom`). |
| `CodeLead.Workflow.Transition` | `from`, `to`, `trigger` (`:human`/`:auto`), `context_policy` (`:carry`/`:reset`), `worktree_policy` (`:keep`/`:discard`). |
| `Tasks.apply_transition/3` | Takes the edge as `{from, to}`; derives every field change from the edge's policies and the target stage's type; writes, records the step, broadcasts. |
| `Runtime.advance/3` | The same edge plus side effects: `prepare` → write → worktree policy → `on_enter`. |
| `Runtime.StageEffects` | The only stage-type → behaviour map: `prepare/2` (pre-commit, may veto) and `on_enter/3` (post-commit). |

The named functions below name an edge and supply the audit summary;
they carry no column logic of their own. An edge the definition does
not contain is `{:error, :invalid_state}`.

`test/code_lead/workflow_test.exs` is the characterisation guardrail:
it transcribes spec §4 and fails if the definition drifts from it.

## Transitions as implemented

| Function | Actor | From (state, run_state) | To | Side effects |
|---|---|---|---|---|
| `move_to_running/1` | human | planning | running, queued | executor guard (eligible `:execute` agent; repo target needs repository; a `:container` task needs a declared repository image — `:missing_execution_env` otherwise); clears `next_prompt` |
| `begin_dispatch/1` | system | running, queued | running, dispatched | runtime provisions context next |
| `mark_executing/2` | system | running, dispatched | running, executing | persists `acp_session_id` when given |
| `complete_run/1` | system | running, executing | review, idle | the one automatic column change (completion signal) |
| `fail_run/2` | system | running, queued/dispatched/executing | running, failed | attention `:run_failed`; **no column change** |
| `retry_run/1` | human | running, failed | running, queued | clears attention |
| `cancel_run/1` | human | running, any | planning, idle | **keeps** worktree/branch/session; runtime kills the agent process and releases the task container (`release_context/1` — recreated on the next start) |
| `request_changes/2` | human | review | running, queued | **keeps** worktree/branch/session — and the task container, which the rework reuses; feedback stored in `next_prompt` |
| `send_back_to_planning/1` | human | review | planning, idle | **clears** worktree/branch/session/next_prompt; runtime discards worktree + branch, the task container, and the agent home. The transition commits even when file removal fails (root-owned leftovers of a container run) — the failure comes back as `{:ok, task, {:cleanup_failed, reason}}`, is flashed, and lands as a task step; the next dispatch refuses to build on the leftover with a host-side remedy |
| `begin_finalize/2` | human | review, idle | review, finalizing | **atomic** conditional update (`UPDATE … WHERE state = 'review' AND run_state = 'idle'`) — the double-click and two-users protection for the non-retryable finalizer; clears attention, records the human "approved — finalizing" step. Zero rows → `{:error, :finalizing}` (already claimed) or `{:error, :invalid_state}` |
| `approve/1` (the edge) | system | review, finalizing → done, idle | done, idle | stamps `completed_at`; run by `Runtime.finalize/1` in a supervised worker — the finalizer executes in the task's resolved **finalize mode** before the write (prepare may veto), its link lands in `pr_url`/`pr_url_kind`, and its `cleanup:` decides whether the worktree is pruned — the task container is removed either way (cattle) |
| `fail_finalize/2` | system | review, finalizing | review, idle | attention `:finalize_failed` with the human-readable reason; **no column change** — the `fail_run/2` of the Review stage |
| `archive/1` | human | done | (state unchanged) | sets `archived_at`; the board excludes archived tasks. Reversal is only possible as a raw `archived_at: nil` update — deliberately not a context function or UI action; see [`web-ui.md`](web-ui.md) |
| `delete_task/1` | human | planning or cancelled | (row deleted) | cascades steps/reviewers/messages |

Every transition writes a `:transition` task step (denormalized actor).
Since the multi-user change the human functions are scope-first
(`move_to_running(scope, task)` etc.): they authorize `:operate_task`
through `CodeLead.Accounts.Policy` before moving anything, and a human
step records who acted — the username lands in `executor_name` (where
the literal `"human"` used to be) and the id in `task_steps.user_id`
(nilified if the account is later deleted). System steps keep the
`"system"` literal and a nil user. `archive/2` — which bypasses
`transition/3` because it moves no column — now writes its own
attributed step, closing a former audit gap. `apply_transition/3` stays
authorization-free by design: it is also the system funnel
(`complete_run/1`), and `Runtime.advance/3` authorizes human moves
before any side effect fires. Task creation stamps
`tasks.created_by_id`, which is what the reporter own-task rule reads.
Invalid from-states return `{:error, :invalid_state}`.

`begin_dispatch/1`, `mark_executing/2`, `fail_run/2` and `retry_run/1`
move `run_state` inside the Running stage; `begin_finalize/2` and
`fail_finalize/2` move it inside the Review stage. None are workflow
edges, so they keep their own from-state guards — `run_state` tracks
*system execution inside a stage*, not only Running. `complete_run/1`
is an edge but keeps a `run_state: :executing` guard on top of it: a
queued or failed task is in the Running stage with nothing to hand to
Review. **A `:finalizing` task is frozen**: `apply_transition/3`
refuses every edge with `{:error, :finalizing}` except the finalizer's
own system-actor entry into a `:finalize` stage — a second approve,
request changes, send back, and any board move all wait for the worker
(and entering the `:finalize` stage resets `run_state` to `:idle`, so
success clears the marker structurally). An interrupted finalization
(restart mid-push) is reset at boot by
`CodeLead.Runtime.FinalizeReconciler` to `review/idle` with a
`:finalize_interrupted` attention — never retried, because PR creation
and merge are not idempotent (ADR-0016).

## Deviations / notes vs the spec

- **`next_prompt` column (addition):** "feedback becomes the next
  prompt" must survive the async gap between `request_changes` and
  scheduler dispatch, so the feedback is persisted on the task and
  cleared on dispatch-from-planning. Not in spec §3; pure mechanics.
  It is also the fork in `TaskRunner.build_prompt/1`: a rework prompt is
  the stored feedback verbatim, while a fresh dispatch composes
  title/description/spec **plus the Decisions block** from resolved
  planning findings (`Findings.decisions_block/1` — see
  [`planning.md`](planning.md)).
- **`completed_at` column (addition):** the model had no completion
  timestamp — `updated_at` moves on every edit and archive, and the
  audit trail only records it as the prose summary `"approved — Done"`.
  Throughput and lead time need a real one, so `approve/1` stamps it.
  It is written **exactly once**: no transition leaves `:done`, so
  nothing clears it, and `archive/1` deliberately leaves it intact —
  archiving hides a card, it does not un-do the work. Any future reopen
  transition must set `completed_at: nil` or throughput double-counts.
- **`task_state_transitions` table (addition):** a general history of
  every Kanban-column move (`from_state`/`to_state`/`inserted_at`),
  written by `transition/3` whenever `changes` carries `:state` — i.e.
  every `apply_transition/3` call, never the direct `transition/3`
  calls that only move `run_state` within a stage (`begin_dispatch/1`,
  `mark_executing/2`, `retry_run/1`, `clear_schedule/1`). Added because
  Running is re-enterable (cancel→retry, request-changes rework) and no
  column captures "first entered Running" — `Tasks.avg_cycle_time_ms/1`
  reads it as `min(inserted_at)` per task, filtered to `to_state:
  :running`, so a rework re-entry never reads as a fresh start. Unlike
  `completed_at`, this is a table rather than another one-off column:
  the same shape answers any future per-stage timing question without
  another migration. No backfill — tasks completed before this table
  existed have no rows and are excluded from the cycle-time average
  rather than counted wrong.
- `attention := :review_ready` is set by the review fan-out once the
  cycle completes (Step 11); until reviewers exist, entry into Review
  carries no attention.
- `:cancelled` exists in the state enum (per spec §3) but no MVP
  transition produces it — cancel returns to Planning per spec §4. It
  is a terminal task state, **not** a workflow stage.
- **The executor guard is keyed on the target stage type**, so
  `request_changes/2` runs it too — Review → Running enters an
  `:execute` stage. It can only bite if the executor was made
  ineligible while the task sat in Review; previously that case slipped
  through to a failed dispatch.
  `Tasks.startable/2` / `startable?/2` expose the same check — eligible
  executor, repository for `:repo` targets. `Runtime.startable/2` /
  `startable?/2` wrap it with the live-process rule below and are what
  the board and task page call, so both surfaces hide or disable
  Start/Schedule for the same reasons a click would be refused.
- **A live planning survey freezes the card.** Edges leaving a `:plan`
  stage — and `Runtime.delete_task/2`, since delete is not an edge —
  refuse with `{:error, :planning_agent_running}` while the task's
  `{task_id, :plan}` registry slot is held (see
  [`planning.md`](planning.md)). The guard lives in `CodeLead.Runtime`
  (`check_stage_exit/2` inside `advance/3`), not in `Tasks`: knowing
  about live processes is the runtime layer's job.
- **`move_to_running/1` no longer requires `run_state: :idle`.** The
  edge lookup rejects every from-state but `:planning`, and a Planning
  task is always idle. (A Planning task *can* now have a live survey
  process — that is the runtime-layer guard above, still not a
  `run_state`.) The redundant guard went with the hand-written
  transition bodies.
- **`attention` clears on human edges only.** Every human handoff
  resolves whatever flagged the card; the one `:auto` edge (completion)
  leaves it to the Review stage's own fan-out, which raises
  `:review_ready`. This is what the per-transition change maps did
  before, now expressed as a rule.
- **`execution_env` is re-derived from the repository whenever the
  repository selection changes** (`Tasks.derive_execution_env/2`,
  private): a `:devcontainer` repo switches the task to `:container`
  (only if licensed — otherwise it stays `:local`), anything else
  switches it to `:local`. Creation counts as a change from no
  repository, so a new task's execution shape is derived silently,
  with no UI feedback until the task page is opened. An edit that
  leaves the repository untouched never re-derives, so a manual
  Execution choice on the task page sticks.

## Two layers: Tasks (data) vs Runtime (side effects)

`CodeLead.Tasks` holds the pure state machine. `CodeLead.Runtime` is
the human-facing run control that adds the runtime side effects —
dispatching agents through the scheduler, terminating processes,
kicking the queue — and is what the future LiveView (and the IEx
console) calls for those actions:

| Action | Call |
|---|---|
| start a planned task | `Runtime.start_task(task)` |
| cancel a run | `Runtime.cancel_task(task)` |
| retry after failure | `Runtime.retry_task(task)` |
| approve/deny a permission escalation | `Runtime.answer_permission(task, request_id, true/false)` |
| request changes from Review | `Runtime.request_changes(task, feedback)` |
| send back to Planning (discard context) | `Runtime.send_back_to_planning(task)` |
| approve (human, returns immediately: claims the task and spawns the finalize worker) | `Runtime.approve(scope, task)` |
| finalize → Done (system, blocking: PR, merge, squash, artifact, commit-to-path; run by the worker, callable synchronously after `Tasks.begin_finalize/2`) | `Runtime.finalize(task)` |
| run completed → Review (called by the runner) | `Runtime.complete_run(task)` |
| delete a Planning task (guarded against a live survey) | `Runtime.delete_task(scope, task)` |
| re-attempt queued tasks | `Runtime.kick_queue()` |

Each of those is `Runtime.advance/3` with an edge and a summary. The
order inside `advance/3` is load-bearing: the edge resolves first (an
illegal move costs nothing), then the target stage's `prepare/2`, which
can still veto — that is why finalization is a pre-commit hook, so a
failed push leaves the task in Review rather than landing it in Done
with nothing pushed. (Since ADR-0016 the *caller* of the finalize edge
moved off the LiveView into a supervised worker — the order inside
`advance/3` stayed exactly as it was; only who runs it changed.) Only
then is the state written, the edge's
worktree policy applied (teardown for `:discard`), and the stage's
`on_enter/3` fired: `:execute` asks the scheduler to dispatch,
`:review` fans the reviewers out, `:finalize` records the commit step,
stores the forge link it produced (`pr_url`/`pr_url_kind`), and prunes
the execution context if the outcome asked it to, `:plan` and
`:custom` do nothing.

`retry_task/1` is not on that path — a retry moves `run_state` inside
the Running stage, so it calls `Tasks.retry_run/1` and re-dispatches
directly. `cancel_task/1` terminates the agent before advancing;
stopping a process is an exit effect, and the seam has no exit hook.
The Review-exit actions do the advisory analogue: `request_changes/3`
and `send_back_to_planning/2` call `LiveRuns.cancel_advisory/1` before
advancing, and `Runtime.finalize/1` does the same as its first act
after registering `{task_id, :finalize}` — so no reviewer is still
reading a worktree the edge is about to discard or prune (see
[`reviews.md`](reviews.md)).

## Finalize modes

What Approve → Done *does* is a **mode**, resolved from three sources
in order — the task's own `finalize_mode`, the project default, the
target's built-in:

```
Projects.finalize_defaults(project_id)   # parses projects.settings["finalize"]
Tasks.finalize_mode(task)                # the one place all three are joined
Finalizer.resolve_mode(target, task_mode, project_mode)   # pure, DB-free
```

`resolve_mode/3` is pure so the Approve button can be labelled with the
very value the finalizer will run (`Format.finalize_action/2`); the
label and the behaviour cannot drift. The two mode sets are disjoint per
target, which is what lets a mode stranded by a Planning target change
be *skipped* rather than rejected.

| target | mode | Done |
|---|---|---|
| `:repo` | `:pull_request` (default) | commit remainder, push branch, open PR/MR or return a compare link |
| `:repo` | `:merge` | …then merge the branch into the default branch and push it |
| `:repo` | `:squash` | …the same, as a single commit |
| `:folder` | `:artifact` (default) | the task folder is the download — **empty is `{:error, :no_artifact}`**, since the folder is provisioned before the run and an agent that answered in chat leaves one behind that exists and holds nothing |
| `:folder` | `:commit_to_path` | commit the folder into a repository path on its own branch |

**Cleanup is outcome data, not edge policy.** Every outcome carries
`cleanup: :keep_context | :prune_context`, and `on_enter(:finalize, …)`
acts on it *after* the write. The `review → done` edge stays
`worktree_policy: :keep` on purpose: the policy fires before the
finalizer has run, so it cannot know whether the merge succeeded or
which mode ran, and on a `:folder` target it would delete the artifact
Done just produced. `:repo` modes prune (the work is on the remote
either way, and merge/squash have already deleted the remote branch);
folder modes keep. `branch_name` survives pruning — it still names what
was pushed or merged. There is a named test guarding this in
`workflow_test.exs`; see architecture spec §4.1.

The scheduler (`CodeLead.Scheduler.PassThrough`) runs an **ordered list
of gates**, short-circuiting on the first hold; held tasks stay
`run_state: :queued`. The queue is kicked after each run completes.

| Gate | Holds when | Reason |
|---|---|---|
| `ScheduleGate` | `scheduled_at` is set and still in the future | `{:hold, {:scheduled, at}}` |
| `BudgetGate` | a project/org limit is reached month-to-date (`Costs.check_budget/1`) | `{:hold, :budget}` |
| `CapacityGate` | `max_concurrent_runs` live runners exist | `{:hold, :capacity}` |

Gates compose rather than exclude, which is the point: a scheduled run
is still budget- and capacity-checked when its time comes. The planned
subscription-window behaviour is a `WindowGate` added to that list, not
a second `Scheduler` impl. Order matters — `ScheduleGate` first, so a
task waiting on its clock says so instead of reporting a budget that
may well change before it runs.

**Scheduled runs.** `tasks.scheduled_at` defers dispatch only; the
human still moves the card to Running, so no auto-transition exists and
the executor guard fires at schedule time rather than unattended. When
`ScheduleGate` holds, `StageEffects.try_dispatch/1` books an Oban
wake-up (`Runtime.ScheduledDispatchWorker`, `:dispatch` queue). That
job **re-runs `admit?`** instead of dispatching, and no-ops unless the
task still exists, still sits queued in Running, and still carries the
exact time embedded in its args — so cancel, reschedule, run-early and
delete need no job cancellation. `scheduled_at` clears on dispatch and
on entering a `:plan` stage. A past time dispatches immediately (it is
a "not before" bound). If the server is down at T, Oban runs the job
late on recovery; "skip if more than N late" is a deliberate non-goal,
as is recurrence.

Note: the capacity count has a benign single-node race
under simultaneous dispatch. A crash of the runner process itself (not
the agent — that is handled) can leave a task in `:executing` until a
human cancels; runners are deliberately not restarted.

Each active run is a `Runtime.TaskRunner` GenServer (DynamicSupervisor
+ the run-kind Registry, key `{task_id, :execute}` — see
[`architecture.md`](architecture.md)). It provisions the context,
starts the driver,
persists the ACP session id, writes an `llm_api` executor's text
output to `<context>/output.md` as the artifact, records usage on
result, and broadcasts run events over PubSub:

- `"task:<id>"` → `{:task_event, task_id, event}` — *signals*:
  run_started, message_chunk, question, permission_request,
  run_completed, run_failed, run_cancelled. These drive attention and
  UI reloads.
- `"task:<id>"` → `{:agent_feed, task_id, row}` — a transcript row
  inserted or updated, broadcast by `CodeLead.AgentFeed`. `tool_call`
  travels only this way; there is no `:task_event` for it.

**Two per-task logs, deliberately separate.** `task_steps` is the
workflow audit trail (`:transition`/`:run`/`:review`/`:plan`/`:commit`), what
the Task tab's timeline shows. `agent_events` is the executor
transcript — what the agent said and did — behind the Agent tab. They
were briefly conflated (the Agent tab used to seed itself from task
steps because events weren't persisted), which is exactly the mixing
this split exists to prevent. See
[ADR-0002](adr/0002-persist-agent-transcript.md).

**One message, one row.** Chunks accumulate into a single `streaming:
true` row that a tool call finalizes, so row id order is display order.
But tool calls do *not* only arrive between messages: a background
subagent's calls stream up the same ACP session while the parent is
still talking, and finalizing on those split one sentence across two or
three rows. So a row closed by a tool call stays reopenable — a chunk
arriving within `:message_resume_window_ms` (default 500 ms, in
`Runtime.TaskRunner`) continues it instead of starting a new row. The
window is measured *after* the close because that is the only reliable
discriminator: a genuine turn boundary waits for a tool round trip plus
model latency, background interleaving does not. Rows closed by a
question, permission, result, or shutdown are never reopened — those are
real interruptions.

A rework dispatch (`request_changes/2`, `context_policy: :carry`) sends
the human's feedback as the whole next prompt (`TaskRunner.build_prompt/1`)
and resumes the carried ACP session via `session/load`. Two
consequences land in the transcript: the runner records the feedback
itself as a `:human_message` row right after `:run_started`, so the
Agent tab shows what the human actually asked for; and the driver drops
every `session/update` the harness emits while `session/load` is still
pending, because the ACP spec has it replay the whole prior
conversation before responding, and that history is already in the
transcript from earlier runs (see `docs/agent-drivers.md`).

`send_back_to_planning/1` discards the worktree, branch, and ACP
session, but **keeps** the transcript: history the human may still want
to read is not context the next run would inherit. The discard runs
after the DB write and cannot roll it back — a removal that leaves
files behind surfaces (flash + task step + log) instead of failing the
human's decision; see `docs/git-workspace.md` for the verified-removal
mechanics.

Board notifications are owned by `CodeLead.Tasks` itself: every task
write (transitions, `update_task`, archive/unarchive, attention
changes, `delete_task`) broadcasts `{:board_changed, project_id,
task_id}` on `"project:<id>"`, so human and system changes alike sync
open boards. Subscribe with `Tasks.subscribe_board(project_id)` /
`Tasks.subscribe_task(task_id)` — those helpers own the topic names.
A deleted task's own `TaskLive`, if still mounted (e.g. a second tab),
finds the id already gone on the next `:board_changed` and redirects
to the board rather than reloading it.

A `permission_request` additionally stores the JSON-RPC request id in
`task.attention.ref` (stringified; the `Acp` driver keys its pending
map by string), so the UI can answer via
`Runtime.answer_permission(task, ref, granted?)` even after a reload.
An `agent_question` stores its `ref` the same way, answered with
`Runtime.answer_question(task, ref, {:accept, answers} | :decline |
:cancel)`.

Both are **blocking** escalations: the agent's prompt turn is held open
on the wire, so the run stays `run_state: :executing` and cannot reach
the automatic Running→Review edge until a human settles it (or cancels
the run, whose human-triggered edge clears the attention flag on its
way to Planning). Permission escalations arise for tool calls whose
locations leave the sandbox as well as location-less calls of
destructive or unrecognized kinds (see `docs/agent-drivers.md`).
Cancelling a run settles any still-pending permission on the wire with
a `cancelled` outcome, just as it cancels pending questions. Because
two can be open at once, answering one re-points `attention` at the
oldest still-pending escalation rather than clearing it outright.

## Console usage (IEx)

```elixir
alias CodeLead.{Tasks, Runtime, Planning}

{:ok, task} = Tasks.create_task(project_id, %{title: "Add pricing page", work_type: :code})
{:ok, task} = Tasks.set_executor(task, agent_id)
:ok         = Tasks.set_reviewers(task, [reviewer_id])

Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")
{:ok, task} = Runtime.start_task(task)      # queued → dispatched → executing
flush()                                      # watch the live event stream

{:ok, task} = Runtime.request_changes(task, "please add tests")
{:ok, _task} = Tasks.set_finalize_mode(task, "squash")  # or "" to inherit
Tasks.finalize_mode(task)                     # what Approve will run

# Approve is asynchronous: it claims the task and spawns the worker.
{:ok, task} = Runtime.approve(scope, task)    # run_state: :finalizing
# Synchronous alternative for driving it from a shell:
{:ok, task} = Tasks.begin_finalize(scope, task)
{:ok, task, outcome} = Runtime.finalize(task) # finalize → done
Tasks.board(project_id)
Tasks.steps(task.id)
```

See [`console-api.md`](console-api.md) for the full walkthrough.
