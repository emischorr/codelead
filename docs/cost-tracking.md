# Cost & token tracking (last updated: 2026-08-10)

Implemented in `CodeLead.Costs`.

- Every run (executor **and** each reviewer) is recorded in
  `agent_runs` via `record_run/1` — tokens, cost_cents, status,
  timestamps. Prunable after 14 days.
- `RollupWorker` (Oban, nightly at 02:00 UTC via `Oban.Plugins.Cron`)
  rolls completed (pre-today) days into permanent `daily_metrics`
  (per project per day) with recompute-upserts, then prunes old runs.
- **Spend** = daily_metrics totals + today's not-yet-rolled runs:
  `project_spend/1`, `org_spend/0`, `task_spend/1`.
- **Pricing:** providers report tokens, not money. `with_cost/2`
  prices usage from the `:model_prices` config map (cents per million
  tokens; unknown model → 0; a backend-reported cost wins). Token
  counts are always exact; cost is best-effort.
- **Budgets** are cumulative totals (no period) in MVP:
  `check_budget/1` returns `{:hold, :budget}` when a project or org
  cost/token limit is reached — this backs the scheduler's `admit?`.
  Review runs are cost-tracked but not budget-held.
