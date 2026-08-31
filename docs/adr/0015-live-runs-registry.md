# 0015 — One live-run registry keyed on run kind

## Status

Accepted (2026-08-31).

## Context

`CodeLead.Runtime.Registry` held only executor runs, keyed on the bare
task id. Everything else that acts on a task — the planning survey, the
fanned-out reviewers — ran as anonymous `Task.Supervisor` children whose
pids nobody kept. Three problems shared that root cause:

- **No dedupe, no visibility.** "A survey is running" existed only as a
  LiveView socket assign; a reload showed nothing and a second click
  started a second survey — which, because the survey worktree lives at
  a fixed per-task path that provisioning clears of leftovers, would
  tear the first run's worktree out from under it.
- **Advisory escalations were unanswerable by construction.** The
  Allow/Deny path resolves a process via the registry, and an advisory
  run could not be registered there: its key would collide with the
  executor's.
- **Reviewers outlived the worktree they read.** Send-back-to-Planning
  discarded the worktree while ACP reviewers might still be running in
  it for up to their 15-minute deadline; nothing could cancel them,
  because nothing could find them.

## Decision

One unique registry, keyed on `{task_id, kind[, agent_id]}`, is the
live-process truth for **every** agent run on a task:

- `{task_id, :execute}` — the task runner (its via-tuple).
- `{task_id, :plan}` — the planning survey.
- `{task_id, :review, agent_id}` — one per reviewer agent.

`CodeLead.Runtime.LiveRuns` owns the key shape and every raw registry
call; `RunSupervisor.whereis/1` and `via/1` remain as executor-only
delegates. **Uniqueness of the key is the concurrency rule** — one
executor, one planner, one run per reviewer agent per task —
`{:error, :already_registered}` is the "already running" answer, and no
counter or policy code exists beside it.

Advisory runs **self-register as their first act**, in the spawned
child, before any provisioning (self-registration is what lets the
registry's pid monitor unregister a crashed run with no bookkeeping;
registering before provisioning is what makes the dedupe protect the
survey worktree). They stop via `LiveRuns.cancel_advisory/1`: an
`:advisory_cancel` message that `AdvisoryRun`'s receive loop answers by
cancelling its driver and returning `{:error, :cancelled}`, so the
caller still records its rows — never by killing the process, which
would take the linked driver down rows-unrecorded. `cancel_advisory/1`
waits (bounded) for the runs to exit, because its callers are about to
discard the context the runs are reading.

Consumers that mean *executors* say so: the capacity gate counts
`executor_count/0`, the stalled-run check and the container reaper read
`executor_task_ids/0`, dispatch idempotence looks up
`{task_id, :execute}`. The registry stays node-local; a restart empties
it, and the UI — which derives live-run state from the registry rather
than holding it — honestly shows nothing running.

## Rejected alternatives

- **Task status in the key** (`{task_id, :review_phase, ...}`): a run's
  kind is stable for its lifetime, a task's status is not — a reviewer
  can still be live after the human sends the card back — and
  `stage_type` is an open set through the workflow seam, so status-keyed
  lookups would multiply.
- **A sequence number in the key**: needs a counter, races with itself,
  and encodes a concurrency limit the key shape already provides for
  free.
- **A second registry for advisory runs**: two truths for "what is
  acting on this task", and the executor lookup would still have to
  consult both to answer safety questions like "may I discard this
  worktree".
- **Persisting live-run state on the task row**: a restart would leave
  a lie in the database. Durable state belongs to things that survive
  restarts, which a survey does not; the registry is honest by
  construction.

## Consequences

- Surveys and reviewers are findable, deduplicated, and cancellable;
  the frozen-card guard (`:planning_agent_running`) and Review-exit
  cancellation are built on the lookup.
- The *routing* half of answering advisory escalations is still open:
  Allow/Deny resolves the executor GenServer, not `AdvisoryRun`'s
  receive loop. The registry makes that follow-up possible; it does not
  implement it.
- Every consumer of the registry must now say which kinds it means; a
  future kind (e.g. `{task_id, :finalize}` for background finalization)
  slots in without touching the executor views. What got worse: the key
  shape is a small protocol every reader has to know, where the old
  bare-id registry could be read naively.
- `cancel_advisory/1` blocks its caller for up to the cancel deadline
  while reviewers wind down and record rows — accepted, because the
  alternative is discarding a worktree under a live reader.
