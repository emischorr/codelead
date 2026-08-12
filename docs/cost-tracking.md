# Cost, token & duration tracking (last updated: 2026-08-12)

Implemented in `CodeLead.Costs`.

- Every run (executor **and** each reviewer) is recorded in
  `agent_runs` via `record_run/1` — the token split, cost_cents,
  status, timestamps, and `duration_ms`. Prunable after 14 days.
- **Token split:** `prompt_tokens`, `completion_tokens`,
  `cached_read_tokens`, `cached_write_tokens`, `reasoning_tokens`, and
  the `total_tokens` the backend reported. On a coding run the cache
  reads are usually the bulk of the total, so the split is what makes a
  large number make sense; the Cost card shows it on hover.
- **Duration** is `duration_ms`, measured with `System.monotonic_time/1`
  across the run. `started_at`/`finished_at` are second-granular and
  move with the system clock, so they anchor the timeline while
  `duration_ms` carries the number that gets displayed.
- `RollupWorker` (Oban, nightly at 02:00 UTC via `Oban.Plugins.Cron`)
  rolls completed (pre-today) days into permanent `daily_metrics`
  (per project per day) with recompute-upserts, then prunes old runs.
  The rollup keeps tokens and money only — the split and the duration
  live and die with the raw rows.
- **Spend** groups both tables by day and merges them with **the rollup
  winning** over raw runs for the same day: between the nightly job and
  the 14-day prune a completed day exists in both tables, and the metric
  was computed from those very runs, so summing them doubles the day.
  Every spend query goes through one private `spend_since/2` (window
  start + optional project), so none of them can drift apart. Reading it
  the other way — rollups plus *today's* runs — silently drops each
  completed day the nightly job has not reached yet, which locally is
  all of them; that bug made the sidebar's monthly tile read as a daily
  figure until 2026-08-12.
- Lifetime: `project_spend/1`, `org_spend/0`. Month-to-date:
  `project_spend_month/2`, `org_spend_month/1`,
  `spend_by_project_month/1` — each takes the window start as an
  optional argument that defaults to the 1st of the current UTC month,
  so tests can pin a window instead of depending on the calendar day.
  Per task: `task_spend/1`, `task_duration_ms/1`, `task_runs/1`, and
  `spend_by_task/1`, which batches spend, duration and the distinct
  provider kinds for board cards.
- **Dashboard readouts** (`org_spend_today/0`, `spend_by_project_month/1`,
  `daily_series/1`) are org-wide and grouped —
  `spend_by_project_month/1` is two queries no matter how many projects
  exist, not one per project. In `daily_series/1` days with no activity
  are zero-filled by the query, not the caller.
- `record_run/1` **broadcasts nothing**. Nothing on the cost side has a
  PubSub topic, so any surface showing live spend has to poll — that is
  why `DashboardLive` carries a 30s tick alongside its task
  subscription.
- **Budgets** run on the **calendar month (UTC)**: `check_budget/1`
  compares month-to-date spend against the project and org cost/token
  limits and returns `{:hold, :budget}` when one is reached — this backs
  the scheduler's `admit?`. A hold therefore lifts by itself on the 1st.
  The limits are stored as plain integers on `projects`/`organizations`;
  the period lives in the query, not the schema. Review runs are
  cost-tracked but not budget-held.

## Where the numbers come from

ACP is the primary source and reports both halves of the picture:

- **Tokens** arrive with the terminal `session/prompt` response, in
  ACP's camelCase spelling (`totalTokens`, `inputTokens`,
  `cachedReadTokens`, …). `Acp.extract_usage/1` reads those first and
  falls back to the Anthropic/OpenAI snake_case spellings for other
  harnesses. Reading only the snake_case names silently records zeros —
  that was the bug this tracking was broken by until 2026-08-11.
  `PromptResponse.usage` is marked *experimental* in the ACP schema, so
  a harness may legitimately omit it; when that happens the money below
  still lands and only the token split is missing.
- **Money** arrives mid-run on `sessionUpdate: "usage_update"`
  notifications, as `cost.amount` in `cost.currency` — the harness's own
  cumulative total for the session. One CodeLead run is one prompt turn
  in a freshly spawned subprocess, so that cumulative figure is the
  run's cost. The same notification carries `used`/`size`, which are
  context-window occupancy, **not** tokens billed.

`llm_api` runs report tokens from the provider response and no money.

**Pricing precedence:** a backend-reported `cost_cents` always wins.
`with_cost/2` only prices usage the backend left unpriced, from the
`:model_prices` config map (cents per million tokens, keyed on the
agent's `model_variant`; unknown model → 0). That table has no cache
rates, so a locally derived figure understates any cache-heavy run —
prefer the harness's number wherever it exists. Token counts are always
exact; cost is best-effort.

**Billing mode.** `Agents.billing_mode/1` maps a provider kind to how
its money should be read: `:anthropic_subscription` → `:estimated` (the
harness reports an API-equivalent figure, but the seat is what's
actually billed), `:ollama` → `:free`, everything else → `:exact`. It
accepts a list for work spanning providers, where an estimate anywhere
makes the whole figure an estimate. `CodeLeadWeb.Format.cost/2` renders
the three modes as `$0.42`, `~$0.42 est`, and `—`.

**Runs that never finish.** A cancel, a harness crash, or a protocol
error still burned money the harness already reported. The ACP driver
falls back to its last `usage_update` snapshot, and `TaskRunner` falls
back to the last `{:usage, _}` event it saw, so a dead run is never
recorded as free.
