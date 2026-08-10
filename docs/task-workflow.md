# Task workflow (last updated: 2026-08-10)

Implementation of architecture spec §4 in `CodeLead.Tasks`
(lib/code_lead/tasks.ex). `state` is the Kanban column
(planning/running/review/done/cancelled), `run_state` tracks execution
inside Running (idle/queued/dispatched/executing/failed). `archived_at`
is orthogonal to `state`.

## Transitions as implemented

| Function | Actor | From (state, run_state) | To | Side effects |
|---|---|---|---|---|
| `move_to_running/1` | human | planning, idle | running, queued | executor guard (eligible `:execute` agent; repo target needs repository); clears `next_prompt` |
| `begin_dispatch/1` | system | running, queued | running, dispatched | runtime provisions context next |
| `mark_executing/2` | system | running, dispatched | running, executing | persists `acp_session_id` when given |
| `complete_run/1` | system | running, executing | review, idle | the one automatic column change (completion signal) |
| `fail_run/2` | system | running, queued/dispatched/executing | running, failed | attention `:run_failed`; **no column change** |
| `retry_run/1` | human | running, failed | running, queued | clears attention |
| `cancel_run/1` | human | running, any | planning, idle | **keeps** worktree/branch/session; runtime kills the agent process |
| `request_changes/2` | human | review | running, queued | **keeps** worktree/branch/session; feedback stored in `next_prompt` |
| `send_back_to_planning/1` | human | review | planning, idle | **clears** worktree/branch/session/next_prompt; runtime discards worktree + branch |
| `approve/1` | human | review | done, idle | finalizer (commit/push/PR or artifact) runs around this |
| `archive/1` / `unarchive/1` | human | done | (state unchanged) | sets/clears `archived_at`; board/list exclude archived |
| `delete_task/1` | human | planning or cancelled | (row deleted) | cascades steps/reviewers/messages |

Every transition writes a `:transition` task step (denormalized actor).
Invalid from-states return `{:error, :invalid_state}`.

## Deviations / notes vs the spec

- **`next_prompt` column (addition):** "feedback becomes the next
  prompt" must survive the async gap between `request_changes` and
  scheduler dispatch, so the feedback is persisted on the task and
  cleared on dispatch-from-planning. Not in spec §3; pure mechanics.
- `attention := :review_ready` is set by the review fan-out once the
  cycle completes (Step 11); until reviewers exist, entry into Review
  carries no attention.
- `:cancelled` exists in the state enum (per spec §3) but no MVP
  transition produces it — cancel returns to Planning per spec §4.

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
| re-attempt queued tasks | `Runtime.kick_queue()` |

The scheduler (`CodeLead.Scheduler.PassThrough`) admits unless a
budget limit is reached (`{:hold, :budget}`, via `Costs.check_budget/1`)
or `max_concurrent_runs` live runners exist (`{:hold, :capacity}`);
held tasks stay `run_state: :queued`. The queue is kicked after each
run completes. Note: the capacity count has a benign single-node race
under simultaneous dispatch. A crash of the runner process itself (not
the agent — that is handled) can leave a task in `:executing` until a
human cancels; runners are deliberately not restarted.

Each active run is a `Runtime.TaskRunner` GenServer (DynamicSupervisor
+ Registry by task id). It provisions the context, starts the driver,
persists the ACP session id, writes an `llm_api` executor's text
output to `<context>/output.md` as the artifact, records usage on
result, and broadcasts over PubSub:

- `"task:<id>"` → `{:task_event, task_id, event}` (run_started,
  message_chunk, tool_call, question, permission_request,
  run_completed, run_failed, run_cancelled)
- `"project:<id>"` → `{:board_changed, project_id, task_id}`

## Console usage (IEx)

```elixir
alias CodeLead.{Tasks, Runtime, Planning}

{:ok, task} = Tasks.create_task(project_id, %{title: "Add pricing page", work_type: :code})
{:ok, task} = Tasks.set_executor(task, agent_id)
:ok         = Tasks.set_reviewers(task, [reviewer_id])

Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")
{:ok, task} = Runtime.start_task(task)      # queued → dispatched → executing
flush()                                      # watch the live event stream

{:ok, task} = Tasks.request_changes(task, "please add tests")
{:ok, task} = Tasks.approve(task)           # → done
Tasks.board(project_id)
Tasks.steps(task.id)
```
