# Task workflow (last updated: 2026-08-12)

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
| `move_to_running/1` | human | planning | running, queued | executor guard (eligible `:execute` agent; repo target needs repository); clears `next_prompt` |
| `begin_dispatch/1` | system | running, queued | running, dispatched | runtime provisions context next |
| `mark_executing/2` | system | running, dispatched | running, executing | persists `acp_session_id` when given |
| `complete_run/1` | system | running, executing | review, idle | the one automatic column change (completion signal) |
| `fail_run/2` | system | running, queued/dispatched/executing | running, failed | attention `:run_failed`; **no column change** |
| `retry_run/1` | human | running, failed | running, queued | clears attention |
| `cancel_run/1` | human | running, any | planning, idle | **keeps** worktree/branch/session; runtime kills the agent process |
| `request_changes/2` | human | review | running, queued | **keeps** worktree/branch/session; feedback stored in `next_prompt` |
| `send_back_to_planning/1` | human | review | planning, idle | **clears** worktree/branch/session/next_prompt; runtime discards worktree + branch |
| `approve/1` | human | review | done, idle | stamps `completed_at`; the finalizer runs around this in the task's resolved **finalize mode**, its link lands in `pr_url`/`pr_url_kind`, and its `cleanup:` decides whether the worktree is pruned |
| `archive/1` / `unarchive/1` | human | done | (state unchanged) | sets/clears `archived_at`; board/list exclude archived |
| `delete_task/1` | human | planning or cancelled | (row deleted) | cascades steps/reviewers/messages |

Every transition writes a `:transition` task step (denormalized actor).
Invalid from-states return `{:error, :invalid_state}`.

`begin_dispatch/1`, `mark_executing/2`, `fail_run/2` and `retry_run/1`
move `run_state` inside the Running stage and are **not** workflow
edges, so they keep their own from-state guards. `complete_run/1` is an
edge but keeps a `run_state: :executing` guard on top of it: a queued
or failed task is in the Running stage with nothing to hand to Review.

## Deviations / notes vs the spec

- **`next_prompt` column (addition):** "feedback becomes the next
  prompt" must survive the async gap between `request_changes` and
  scheduler dispatch, so the feedback is persisted on the task and
  cleared on dispatch-from-planning. Not in spec §3; pure mechanics.
- **`completed_at` column (addition):** the model had no completion
  timestamp — `updated_at` moves on every edit and archive, and the
  audit trail only records it as the prose summary `"approved — Done"`.
  Throughput and lead time need a real one, so `approve/1` stamps it.
  It is written **exactly once**: no transition leaves `:done`, so
  nothing clears it, and `archive/1` deliberately leaves it intact —
  archiving hides a card, it does not un-do the work. Any future reopen
  transition must set `completed_at: nil` or throughput double-counts.
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
- **`move_to_running/1` no longer requires `run_state: :idle`.** The
  edge lookup rejects every from-state but `:planning`, and a Planning
  task is always idle. The redundant guard went with the hand-written
  transition bodies.
- **`attention` clears on human edges only.** Every human handoff
  resolves whatever flagged the card; the one `:auto` edge (completion)
  leaves it to the Review stage's own fan-out, which raises
  `:review_ready`. This is what the per-transition change maps did
  before, now expressed as a rule.

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
| approve → Done (finalize by mode: PR, merge, squash, artifact, commit-to-path) | `Runtime.approve(task)` |
| run completed → Review (called by the runner) | `Runtime.complete_run(task)` |
| re-attempt queued tasks | `Runtime.kick_queue()` |

Each of those is `Runtime.advance/3` with an edge and a summary. The
order inside `advance/3` is load-bearing: the edge resolves first (an
illegal move costs nothing), then the target stage's `prepare/2`, which
can still veto — that is why finalization is a pre-commit hook, so a
failed push leaves the task in Review rather than landing it in Done
with nothing pushed. Only then is the state written, the edge's
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
+ Registry by task id). It provisions the context, starts the driver,
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

`send_back_to_planning/1` discards the worktree, branch, and ACP
session, but **keeps** the transcript: history the human may still want
to read is not context the next run would inherit.

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
way to Planning). Because two can be open at once, answering one
re-points `attention` at the oldest still-pending escalation rather
than clearing it outright.

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
{:ok, task, outcome} = Runtime.approve(task)  # finalize → done
Tasks.board(project_id)
Tasks.steps(task.id)
```

See [`console-api.md`](console-api.md) for the full walkthrough.
