# Review cycle (last updated: 2026-08-10)

Implemented in `CodeLead.Reviews`. Reviewers are ordinary agents with
`:review` in `roles`, matched to the task's work type, selected per
task (pre-filled from project defaults) — not a separate abstraction.

## Fan-out

On Running → Review the `TaskRunner` calls `Reviews.start_cycle/1`:

- **No reviewers selected** → Review is human-only; attention
  `:review_ready` is raised immediately (cycle 0).
- Otherwise one run per reviewer is fanned out concurrently (max 4)
  under `CodeLead.TaskSupervisor`, through the ordinary drivers:
  - `llm_api` reviewers get the artifact in-prompt: the branch diff for
    `:repo` targets, the file listing + text file contents for
    `:folder` targets (truncated at 60k chars).
  - `acp` reviewers get the execution context with `read_only: true` —
    `fs/write_text_file` is denied by the driver; reads and terminal
    stay available.
- Each reviewer writes a `reviews` row (advisory `verdict` parsed from
  a trailing `{"verdict": ...}` JSON line, full text as `findings`),
  an `agent_runs` row (cost-tracked, **not** budget-held), and a
  `:review` task step. A crashed/timed-out reviewer records a
  verdict-less review row and never blocks the cycle.
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
