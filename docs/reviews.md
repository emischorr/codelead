# Review cycle (last updated: 2026-08-31, reviewers registered as live runs)

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
- Reviewers report in the shared **two-part contract** the planning
  survey uses (`Findings.Report.output_contract/1`): a markdown
  narrative plus one fenced JSON block — with a `"verdict"` key added
  for reviews. The advisory `verdict` is read from that payload
  (`Report.verdict/1`); a bare trailing `{"verdict": ...}` line still
  parses as fallback for old-contract reviewers, and the payload guard
  accepting a lone `"verdict"` object means a verdict-only reply never
  renders as a JSON body.
- Each reviewer writes a `reviews` row (`findings` holds the **raw
  report verbatim** — the review analogue of a `planning_messages`
  turn; narrative vs. raw is derived at render time), an `agent_runs`
  row (cost-tracked, **not** budget-held), and a `:review` task step.
  The report's itemized findings land as `phase: :review` rows via
  `Findings.apply_report(..., prior_scope: :agent)` — each reviewer's
  prompt lists only its **own** prior findings to classify, so
  fanned-out reviewers cannot reclassify each other's rows. A report
  with no parseable block writes no rows and degrades to the raw
  report in the UI; a crashed/timed-out reviewer records a
  verdict-less review row and never blocks the cycle.
- The review prompt carries the planning **Decisions block**
  (`Findings.decisions_block/1` — planning-phase only; see
  [`planning.md`](planning.md)), so reviewers judge the artifact
  against what the human decided, not only the spec.
- In the Review tab each latest-cycle reviewer gets its own box
  (agent name + verdict badge) with the narrative, the severity-sorted
  finding rows (shared `FindingsComponents.finding_row/1`), and a
  "Show raw report" fallback (forced when parsing failed). Findings
  are addressable/dismissable while the task is in Review; unlike
  planning, an addressed review finding needs **no note** — the note
  is an optional steer, not a decision. Addressed-and-still-open
  review findings are collected by `Findings.review_feedback_block/1`
  and **prefilled** into the Request-changes textarea when the modal
  opens; the human edits freely and the submitted text becomes
  `next_prompt` unchanged.
- A reviewer that asks a question or hits a permission escalation
  raises the ordinary `attention` field and keeps waiting; its run ends
  on `AdvisoryRun`'s own 15-minute deadline (the outer stream timeout is
  a minute longer, so the deadline that cancels the driver and still
  records a row is the one that fires). Neither is answerable for an
  advisory run — see the gap noted in [`planning.md`](planning.md).
- Each reviewer run registers itself in `CodeLead.Runtime.LiveRuns`
  under `{task_id, :review, agent_id}` as its first act — the key's
  uniqueness is the one-run-per-reviewer rule, and the registry (not
  any state on the task) is the truth about which reviewers are still
  live. See [`architecture.md`](architecture.md).
- When the cycle completes: attention `:review_ready` +
  `{:review_cycle_completed, cycle}` on the task topic — unless the
  task has already left Review under a human decision (a cancelled
  cycle must not raise attention on a card back in Planning; the
  broadcast still fires). Cycles increment per Review entry; prior
  cycles are retained for audit.

## Human decision (all via `CodeLead.Runtime`)

- `Runtime.request_changes(task, feedback)` — keeps worktree, branch,
  and ACP session; feedback becomes the next prompt; re-queued through
  the scheduler; next Review entry runs cycle N+1.
- `Runtime.send_back_to_planning(task)` — discards worktree, deletes
  the feature branch, clears the session (executor teardown
  `keep: false`).
- `Tasks.approve(task)` — → Done (finalization in Step 12).

Verdicts gate nothing; the human weighs all findings.

## Leaving Review cancels live reviewers

All three decisions above supersede pending advisory output, so each
first calls `LiveRuns.cancel_advisory/1`: every registered advisory run
on the task receives `:advisory_cancel`, on which `AdvisoryRun` cancels
its driver and returns `{:error, :cancelled}` — the reviewer still
records its rows (`reviews` row with no verdict, `agent_runs` with
status `:cancelled`, its `:review` step) and the cycle completes
normally. `cancel_advisory/1` **waits** (bounded, 15s) for the
processes to exit before the transition proceeds, because
send-back's worktree discard and approve's finalize-prune must not run
under a live reader; a straggler past the deadline is logged and the
human's decision stands. Never cancel a reviewer by killing its
process: the driver is linked, so a kill takes the harness down with
no rows recorded — that is what the `:advisory_cancel` path exists to
avoid.
