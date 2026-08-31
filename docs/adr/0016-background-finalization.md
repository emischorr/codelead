# 0016 — Background finalization behind an atomic marker

## Status

Accepted (2026-08-31).

## Context

Approve → Done ran the entire finalization — git push, clone, merge,
the forge PR POST — inline in the approving user's LiveView process,
inside `StageEffects.prepare(:finalize, ...)`. The prepare-before-write
ordering is correct (a failed push must leave the task in Review), but
the owner was wrong: git shell-outs have no timeout, so the click could
block for minutes, and if the LiveView died mid-push — a closed tab, a
deploy — the branch might be pushed or a PR opened with nothing
recorded. The task then sat in Review looking untouched, and a second
Approve re-POSTed the PR; GitHub's 422 "already exists" was swallowed
into the compare-link fallback, overwriting the real PR URL.

Finalization is also the one piece of the workflow that is **not
idempotent from the outside**: pushing again is safe, but PR creation
and merging are not. Whatever owns it must make "exactly one
finalization at a time" a hard guarantee and must never blindly re-run
an interrupted one.

## Decision

Approve splits into a human half and a system half:

- **`Tasks.begin_finalize/2`** claims the task with an atomic
  conditional update — `UPDATE … WHERE state = 'review' AND run_state =
  'idle'` setting `run_state: :finalizing` — never read-then-write.
  The row count is the arbiter: two users, or one double click, get
  exactly one claim; the loser sees `{:error, :finalizing}`. The task
  **stays in Review** while finalizing; `run_state` widens from
  "execution inside Running" to *system execution inside a stage*.
- **`Runtime.finalize/1`** runs in a supervised `TaskSupervisor`
  worker: it registers `{task_id, :finalize}` in the live-run registry
  (ADR-0015), cancels live reviewers before the prune, then runs the
  unchanged `advance({:review, :done}, actor: :system, ...)` body.
  Success broadcasts `{:finalize_completed, outcome}`; any error,
  raise, or exit lands in `Tasks.fail_finalize/2` — back to
  `review/idle` with a `:finalize_failed` attention carrying the same
  human-readable text the flash shows (`Finalizer.error_message/1`,
  core-layer so the runtime may persist it) — and broadcasts
  `{:finalize_failed, reason}`.
- **A `:finalizing` task is frozen.** `apply_transition/3` refuses
  every edge except the finalizer's own system-actor entry into a
  `:finalize` stage. Entering that stage resets `run_state` to `:idle`,
  so success clears the marker structurally. The in-struct guard shares
  the staleness class of every existing guard; the *atomic* claim is
  what protects the non-retryable path.
- **A boot reconciler, never a retry.** `Runtime.FinalizeReconciler`
  resets orphaned `:finalizing` rows to `review/idle` with a
  `:finalize_interrupted` attention telling the human to check the
  remote. A restart mid-push leaves remote state only a human should
  judge.
- **PR creation is idempotent.** `Finalizer.create_pull_request/4`
  first asks the forge for an open PR/MR whose head is the task's
  branch and reuses its URL (`{:ok, url, :reused}`, note "already open
  — reused"), so the human's second approve after an interruption never
  opens a duplicate. A failed lookup degrades to the POST; the 422 →
  compare-link fallback stays for the race the lookup can lose.

## Rejected alternatives

- **An Oban job** — durable retry is exactly the wrong property for a
  non-idempotent push/PR/merge; with `max_attempts: 1` Oban degrades to
  a `Task.Supervisor` child with extra tables, and the task row still
  needs the `:finalizing` marker for the UI and the freeze.
- **A `finalizing` workflow stage or column** — it is not a human
  handoff; the Kanban would show a state no human chose, and every
  future workflow definition would have to carry it.
- **A separate `finalize_state` column** — a second field meaning
  "something is executing on this task" when `run_state` already is
  that field.
- **`start_async` in the LiveView** — survives nothing the inline call
  does not; the process still dies with the view.
- **Auto-retry on boot** — could open a second PR or double-merge; the
  reconciler's honesty (attention + never retry) is the safe version.

## Consequences

- Approve returns in milliseconds; the outcome arrives as an event, so
  the flash moved from the click handler to the event handler — the one
  place `ingest_event/2` flashes.
- The finalize-mode selector and every Review-exit action are disabled
  (and server-refused) while finalizing; the board card wears a
  `finalizing` pill read straight off `run_state`.
- Tests and the IEx console drive the synchronous pair
  (`begin_finalize/2` then `finalize/1`) or await
  `{:finalize_completed, _}`.
- What got worse: an app shutdown mid-push brutally kills the worker,
  so remote state can exist with nothing recorded — exactly the case
  `:finalize_interrupted` plus PR reuse exists to make safe, but
  merge/squash keep a manual-judgment window there. And the freeze
  guard reads the in-memory struct, so a stale view's request-changes
  retains the same (pre-existing) benign race every transition guard
  has.
