# Review cycle (last updated: 2026-08-15)

Implemented in `CodeLead.Reviews`. Reviewers are ordinary agents with
`:review` in `roles`, matched to the task's work type, selected per
task (pre-filled from project defaults) — not a separate abstraction.

The run itself is `CodeLead.AdvisoryRun`, shared with the planning
survey (see [`planning.md`](planning.md)): the same read-only posture
pointed at a different subject. `Reviews` owns only the artifact, the
prompt, the verdict, and the rows.

## Fan-out

The fan-out is the on-entry effect of a `:review` **stage**, not of the
Review column: `Runtime.StageEffects.on_enter/3` calls
`Reviews.start_cycle/1` whenever a task enters a stage of that type
(see [`task-workflow.md`](task-workflow.md)). Today the only such entry
is Running → Review, driven by the `TaskRunner` on a successful result.

`Reviews.start_cycle/1` itself is unchanged by that indirection:

- **No reviewers selected** → Review is human-only; attention
  `:review_ready` is raised immediately (cycle 0).
- Otherwise one run per reviewer is fanned out concurrently (max 4)
  under `CodeLead.TaskSupervisor`, through the ordinary drivers:
  - `llm_api` reviewers get the artifact in-prompt: the branch diff for
    `:repo` targets, the file listing + text file contents for
    `:folder` targets (truncated at 60k chars).
  - `acp` reviewers get the execution context with `read_only: true` —
    `fs/write_text_file` is denied by the driver; reads and terminal
    stay available. Because the terminal is not gated, a read-only
    posture contains a *disposable* context, not a shared one. On a
    container task the reviewer execs into the **same** task container
    (the context carries `Executor.for_task/1`, and the executor's
    `spawn` recreates the container if it was removed in between) — so
    reviewer commands hit the same toolchain the executor built
    against.
- Each reviewer writes a `reviews` row (advisory `verdict` parsed from
  a trailing `{"verdict": ...}` JSON line, full text as `findings`),
  an `agent_runs` row (cost-tracked, **not** budget-held), and a
  `:review` task step. A crashed/timed-out reviewer records a
  verdict-less review row and never blocks the cycle.
- A reviewer that asks a question or hits a permission escalation
  raises the ordinary `attention` field and keeps waiting; its run ends
  on `AdvisoryRun`'s own 15-minute deadline (the outer stream timeout is
  a minute longer, so the deadline that cancels the driver and still
  records a row is the one that fires). Neither is answerable for an
  advisory run — see the gap noted in [`planning.md`](planning.md).
- When the cycle completes: attention `:review_ready` +
  `{:review_cycle_completed, cycle}` on the task topic. Cycles
  increment per Review entry; prior cycles are retained for audit.

## Human decision (all via `CodeLead.Runtime`)

- `Runtime.request_changes(task, feedback)` — keeps worktree, branch,
  and ACP session; feedback becomes the next prompt; re-queued through
  the scheduler; next Review entry runs cycle N+1.
- `Runtime.send_back_to_planning(task)` — discards worktree, deletes
  the feature branch, clears the session (executor teardown
  `keep: false`).
- `Tasks.approve(task)` — → Done (finalization in Step 12).

Verdicts gate nothing; the human weighs all findings.
