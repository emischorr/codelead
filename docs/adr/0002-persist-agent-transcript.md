# 0002 — Persist the executor transcript in its own table

## Status

Accepted (2026-08-11)

## Context

The normalized driver event stream fed four consumers (architecture
spec §6): the live UI over PubSub, attention, the `task_steps` audit
trail, and `agent_runs` usage. Only the first three of those were
durable, and none of them held what the agent actually said.

Agent output therefore existed nowhere but the memory of whichever
LiveView happened to be mounted. Consequences, all of them reported as
bugs:

- Navigating away from the Agent tab lost the run's output. Opening the
  tab mid-run — the normal case, since what draws a human to it is an
  agent question — showed an empty feed.
- To have *something* after a reload, `TaskLive` seeded the feed from
  `task_steps`. That is the workflow audit trail: the Agent tab filled
  up with "moved to Running", "approved — Done", the same rows the Task
  tab's timeline renders. Two logs with different purposes were being
  rendered as one.
- ACP emits `tool_call` and `tool_call_update` as the same normalized
  event, so one logical tool call arrived two or three times. With no
  identity to correlate on, the feed rendered a card per status update.

Correlating tool calls, restoring history, and separating the two logs
are all the same missing thing: a durable, identified record of the
run's events.

The architecture spec's data model has no such table. `task_steps` is
explicitly the coarse audit trail ("Denormalized so agent deletion is
graceful"), one row per transition/run/review/commit.

## Decision

Add an `agent_events` table and a `CodeLead.AgentFeed` context holding
the executor transcript, separate from `task_steps`.

- **Not `task_steps`.** Mixing them is what produced the leak, and the
  two have opposite shapes: audit rows are few, immutable, and
  human-authored in tone; transcript rows are many, mutable (a tool
  call advances its status in place; a message grows as it streams),
  and prunable.
- **Its own context, not `CodeLead.Tasks`.** `Tasks` owns the state
  machine; the transcript is a write-only-then-read log with no bearing
  on state. Keeping it out preserves "task state is derived from
  protocol events" as a statement about `Tasks`, not a hope.
- **`TaskRunner` is the single writer.** One runner exists per active
  task and lives for the whole run, so correlation state (the open
  message row, `toolCallId → row`, `permission ref → row`) lives in its
  process state and merges happen in Elixir. No upsert, no read-modify-
  write race, and merging a jsonb `data` map stays trivial.
- **The open message row is persisted, not buffered.** Chunks
  accumulate into one `streaming: true` row rewritten on a short
  debounce, always finalized before any other row is written. The
  alternative — buffering in the runner and having a mounting LiveView
  ask for the buffer — needs a `GenServer.call` into a process that may
  be blocked cloning a repository, helps only connected mounts, and
  loses the partial message when the runner dies.
- **`{:agent_feed, task_id, row}` is a second payload on the existing
  task topic**, distinct from `{:task_event, task_id, event}`. Signals
  (attention, run lifecycle, the live chunk delta) and transcript rows
  have different consumers and different lifetimes.

## Consequences

- The Agent tab survives navigation, reloads, and mid-run mounts, and
  a run's history outlives the LiveView that watched it.
- Agent output is now durable data, with the retention and privacy
  duties that implies. Tool input is truncated and redacted before it
  is stored (spec §8 forbids project env reaching persisted logs), and
  the tool's `content` is not stored at all. `agent_events` is the
  bulkiest per-task table and needs pruning like `agent_runs`; no prune
  worker exists yet.
- The transcript is retained across `send_back_to_planning`, which
  discards worktree, branch, and session. Retaining history the human
  may want to read is not the same as feeding it back to the agent.
- The data model now deviates from architecture spec §3. The spec stays
  the target-state source of truth and should be amended to include
  this table.
- Two live paths write the same message text — the chunk delta for
  smoothness and the row for durability. They stay consistent only
  because both originate in the same process, so per-pair message
  ordering makes the row authoritative on arrival. A future writer
  outside `TaskRunner` would break that and must not be added casually.
