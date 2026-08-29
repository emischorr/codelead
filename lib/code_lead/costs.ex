defmodule CodeLead.Costs do
  @moduledoc """
  Usage/cost capture and budgets. Every run's tokens land in
  `agent_runs` (prunable); a nightly Oban job rolls completed days into
  permanent `daily_metrics`. Spend merges both tables per day, the
  rollup winning. Budgets run on the calendar month (UTC) — every limit
  is compared against month-to-date spend and resets on the 1st.
  """

  import Ecto.Query

  alias CodeLead.Accounts
  alias CodeLead.Agents.Agent
  alias CodeLead.Agents.Provider
  alias CodeLead.Costs.AgentRun
  alias CodeLead.Costs.DailyMetric
  alias CodeLead.Repo
  alias CodeLead.Tasks.Task

  @prune_after_days 14

  @type spend :: %{tokens: non_neg_integer(), cost_cents: non_neg_integer()}

  @doc """
  Records one run's usage. `usage` follows the driver contract; a nil
  `cost_cents` is priced via `with_cost/2` by the caller beforehand or
  stays 0.
  """
  @spec record_run(map()) :: {:ok, AgentRun.t()}
  def record_run(attrs) do
    usage = attrs[:usage] || %{}

    Repo.insert(%AgentRun{
      task_id: Map.fetch!(attrs, :task_id),
      task_step_id: attrs[:task_step_id],
      agent_id: attrs[:agent_id],
      provider_id: attrs[:provider_id],
      prompt_tokens: usage[:prompt_tokens] || 0,
      completion_tokens: usage[:completion_tokens] || 0,
      cached_read_tokens: usage[:cached_read_tokens] || 0,
      cached_write_tokens: usage[:cached_write_tokens] || 0,
      reasoning_tokens: usage[:reasoning_tokens] || 0,
      total_tokens: usage[:total_tokens] || 0,
      cost_cents: usage[:cost_cents] || 0,
      status: Map.fetch!(attrs, :status),
      started_at: Map.fetch!(attrs, :started_at),
      finished_at: attrs[:finished_at],
      duration_ms: attrs[:duration_ms]
    })
  end

  @doc """
  Prices a usage map from the configured per-model rates (cents per
  million tokens). Unknown models cost 0. A backend-reported
  `cost_cents` wins — and usually should: the rate table carries no
  cache rates, so a locally derived figure understates any run with
  cache reads or writes.
  """
  @spec with_cost(CodeLead.AgentDriver.usage() | nil, String.t() | nil) ::
          CodeLead.AgentDriver.usage() | nil
  def with_cost(nil, _model), do: nil
  def with_cost(%{cost_cents: cents} = usage, _model) when is_integer(cents), do: usage

  def with_cost(usage, model) do
    prices = Application.get_env(:code_lead, :model_prices, %{})

    case prices[model] do
      %{input_cents_per_mtok: input_rate, output_cents_per_mtok: output_rate} ->
        cents =
          (usage.prompt_tokens * input_rate + usage.completion_tokens * output_rate) / 1_000_000

        %{usage | cost_cents: round(cents)}

      nil ->
        %{usage | cost_cents: 0}
    end
  end

  @doc """
  Lifetime spend for a project.
  """
  @spec project_spend(pos_integer()) :: spend()
  def project_spend(project_id), do: spend_since(nil, project_id)

  @doc """
  Lifetime spend across the organization, or — with a list of project
  ids — across just those projects (a member's dashboard view).
  """
  @spec org_spend([pos_integer()] | nil) :: spend()
  def org_spend(project_ids \\ nil), do: spend_since(nil, project_ids)

  @doc """
  Month-to-date spend for a project — the sidebar's budget tile and the
  project half of the budget gate. `from_date` is the window start;
  tests pass it explicitly to stay off the calendar's clock.
  """
  @spec project_spend_month(pos_integer(), Date.t()) :: spend()
  def project_spend_month(project_id, from_date \\ month_start()),
    do: spend_since(from_date, project_id)

  @doc """
  Month-to-date spend across the organization, optionally restricted to
  a list of project ids.
  """
  @spec org_spend_month(Date.t(), [pos_integer()] | nil) :: spend()
  def org_spend_month(from_date \\ month_start(), project_ids \\ nil),
    do: spend_since(from_date, project_ids)

  @doc """
  Today's not-yet-rolled-up spend across the organization, optionally
  restricted to a list of project ids.
  """
  @spec org_spend_today([pos_integer()] | nil) :: spend()
  def org_spend_today(project_ids \\ nil) do
    AgentRun
    |> where([r], r.started_at >= ^today_start())
    |> runs_for_project(project_ids)
    |> select([r], %{
      tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
      cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer)
    })
    |> Repo.one()
  end

  @doc """
  Month-to-date spend per project in two queries regardless of how many
  projects exist. Projects that have spent nothing this month are
  absent.
  """
  @spec spend_by_project_month(Date.t()) :: %{pos_integer() => spend()}
  def spend_by_project_month(from_date \\ month_start()) do
    rolled =
      Repo.all(
        from m in DailyMetric,
          where: m.date >= ^from_date,
          group_by: [m.project_id, m.date],
          select:
            {{m.project_id, m.date},
             %{
               tokens: type(coalesce(sum(m.total_tokens), 0), :integer),
               cost_cents: type(coalesce(sum(m.cost_cents), 0), :integer)
             }}
      )
      |> Map.new()

    raw =
      Repo.all(
        from r in AgentRun,
          join: t in Task,
          on: t.id == r.task_id,
          where: r.started_at >= ^day_start(from_date),
          group_by: [t.project_id, fragment("date(?)", r.started_at)],
          select:
            {{t.project_id, fragment("date(?)", r.started_at)},
             %{
               tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
               cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer)
             }}
      )
      |> Map.new()

    raw
    |> Map.merge(rolled)
    |> Enum.reduce(%{}, fn {{project_id, _date}, spend}, acc ->
      Map.update(acc, project_id, spend, &add_spend(&1, spend))
    end)
  end

  @doc """
  Org-wide spend per day for the last `days` days, oldest first, with
  missing days zero-filled — the dashboard's spend chart. A list of
  project ids restricts it to those projects.
  """
  @spec daily_series(pos_integer(), [pos_integer()] | nil) :: [
          %{
            date: Date.t(),
            tokens: non_neg_integer(),
            cost_cents: non_neg_integer(),
            run_count: non_neg_integer()
          }
        ]
  def daily_series(days, project_ids \\ nil) do
    from_date = Date.add(Date.utc_today(), -(days - 1))

    raw =
      AgentRun
      |> where([r], r.started_at >= ^day_start(from_date))
      |> runs_for_project(project_ids)
      |> group_by([r], fragment("date(?)", r.started_at))
      |> select(
        [r],
        {fragment("date(?)", r.started_at),
         %{
           tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
           cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer),
           run_count: count(r.id)
         }}
      )
      |> Repo.all()
      |> Map.new()

    rolled =
      DailyMetric
      |> where([m], m.date >= ^from_date)
      |> for_project(project_ids)
      |> group_by([m], m.date)
      |> select(
        [m],
        {m.date,
         %{
           tokens: type(coalesce(sum(m.total_tokens), 0), :integer),
           cost_cents: type(coalesce(sum(m.cost_cents), 0), :integer),
           run_count: type(coalesce(sum(m.run_count), 0), :integer)
         }}
      )
      |> Repo.all()
      |> Map.new()

    # Rolled days win over raw ones — they must not be summed. Between the
    # nightly rollup and the 14-day prune a completed day exists in both
    # tables, and `rollup/0` writes the total it read from those very runs.
    # Raw covers today, which is never rolled, and any completed day the
    # nightly job has not reached yet.
    by_date = Map.merge(raw, rolled)

    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(from_date, offset)

      by_date
      |> Map.get(date, %{tokens: 0, cost_cents: 0, run_count: 0})
      |> Map.put(:date, date)
    end)
  end

  @doc """
  Budget gate for the scheduler: `:ok` or `{:hold, :budget}` when the
  project's or the organization's cost/token limit is reached. Limits
  are month-to-date, so a hold lifts by itself on the 1st.
  """
  @spec check_budget(pos_integer()) :: :ok | {:hold, :budget}
  def check_budget(project_id) do
    project = CodeLead.Projects.get_project!(project_id)
    organization = Accounts.get_organization!()
    project_spend = project_spend_month(project_id)
    org_spend = org_spend_month()

    over? =
      over_limit?(project_spend.cost_cents, project.budget_limit_cents) or
        over_limit?(project_spend.tokens, project.budget_limit_tokens) or
        over_limit?(org_spend.cost_cents, organization.budget_limit_cents) or
        over_limit?(org_spend.tokens, organization.budget_limit_tokens)

    if over?, do: {:hold, :budget}, else: :ok
  end

  @doc """
  Rolls all completed (pre-today) days from `agent_runs` into
  `daily_metrics` and prunes runs older than #{@prune_after_days} days.
  Idempotent — rollups are recomputed upserts.
  """
  @spec rollup() :: :ok
  def rollup do
    now = DateTime.utc_now(:second)

    rows =
      Repo.all(
        from r in AgentRun,
          join: t in Task,
          on: t.id == r.task_id,
          where: r.started_at < ^today_start(),
          group_by: [t.project_id, fragment("date(?)", r.started_at)],
          select: %{
            project_id: t.project_id,
            date: fragment("date(?)", r.started_at),
            total_tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
            cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer),
            run_count: count(r.id)
          }
      )

    entries = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

    Repo.insert_all(DailyMetric, entries,
      on_conflict: {:replace, [:total_tokens, :cost_cents, :run_count, :updated_at]},
      conflict_target: [:project_id, :date]
    )

    prune_before = DateTime.add(now, -@prune_after_days * 24 * 3600, :second)
    Repo.delete_all(from r in AgentRun, where: r.started_at < ^prune_before)

    :ok
  end

  @doc """
  Per-task cost: the sum of its runs (executor and reviewers).
  """
  @spec task_spend(pos_integer()) :: spend()
  def task_spend(task_id) do
    Repo.one(
      from r in AgentRun,
        where: r.task_id == ^task_id,
        select: %{
          tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
          cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer)
        }
    )
  end

  @doc """
  Per-task run meta for many tasks at once (one grouped query, for board
  cards): spend plus total duration and the distinct provider kinds
  involved, which tell the UI whether the money was billed or estimated.
  Tasks without runs are absent from the result.
  """
  @spec spend_by_task([pos_integer()]) :: %{pos_integer() => map()}
  def spend_by_task([]), do: %{}

  def spend_by_task(task_ids) do
    Repo.all(
      from r in AgentRun,
        left_join: p in Provider,
        on: p.id == r.provider_id,
        where: r.task_id in ^task_ids,
        group_by: r.task_id,
        select:
          {r.task_id,
           %{
             tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
             cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer),
             duration_ms: type(coalesce(sum(r.duration_ms), 0), :integer),
             provider_kinds: fragment("array_remove(array_agg(DISTINCT ?), NULL)", p.kind)
           }}
    )
    |> Map.new()
  end

  @doc """
  Today's not-yet-rolled-up spend for a project, for the board header.
  """
  @spec project_spend_today(pos_integer()) :: spend()
  def project_spend_today(project_id) do
    Repo.one(
      from r in AgentRun,
        join: t in Task,
        on: t.id == r.task_id,
        where: t.project_id == ^project_id and r.started_at >= ^today_start(),
        select: %{
          tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
          cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer)
        }
    )
  end

  @doc """
  A task's individual runs, newest first, with the agent name and the
  provider kind joined in — the task page's per-run breakdown. The
  provider kind tells the UI whether the cost is money actually billed
  or a subscription-equivalent estimate.
  """
  @spec task_runs(pos_integer()) :: [map()]
  def task_runs(task_id) do
    Repo.all(
      from r in AgentRun,
        left_join: a in Agent,
        on: a.id == r.agent_id,
        left_join: p in Provider,
        on: p.id == r.provider_id,
        where: r.task_id == ^task_id,
        order_by: [desc: r.started_at, desc: r.id],
        select: %{
          id: r.id,
          status: r.status,
          prompt_tokens: r.prompt_tokens,
          completion_tokens: r.completion_tokens,
          cached_read_tokens: r.cached_read_tokens,
          cached_write_tokens: r.cached_write_tokens,
          reasoning_tokens: r.reasoning_tokens,
          total_tokens: r.total_tokens,
          cost_cents: r.cost_cents,
          started_at: r.started_at,
          finished_at: r.finished_at,
          duration_ms: r.duration_ms,
          agent_name: a.name,
          provider_kind: p.kind
        }
    )
  end

  @doc """
  Total time a task's runs spent executing, in milliseconds. Runs
  recorded before `duration_ms` existed, or that never finished, count
  as zero.
  """
  @spec task_duration_ms(pos_integer()) :: non_neg_integer()
  def task_duration_ms(task_id) do
    Repo.one(
      from r in AgentRun,
        where: r.task_id == ^task_id,
        select: type(coalesce(sum(r.duration_ms), 0), :integer)
    )
  end

  defp over_limit?(_spent, nil), do: false
  defp over_limit?(spent, limit), do: spent >= limit

  # Spend from `from_date` on (nil = lifetime), for one project or, with
  # a nil `project_id`, the whole organization. Both tables are grouped
  # by day and merged with the rollup winning — see `daily_series/1` for
  # why a day present in both must not be summed. Assuming instead that
  # everything before today is already rolled loses every completed day
  # the nightly job has not reached yet.
  defp spend_since(from_date, project_id) do
    rolled = rolled_by_date(from_date, project_id)
    raw = raw_by_date(from_date, project_id)

    raw
    |> Map.merge(rolled)
    |> Enum.reduce(%{tokens: 0, cost_cents: 0}, fn {_date, spend}, acc ->
      add_spend(acc, spend)
    end)
  end

  defp rolled_by_date(from_date, project_id) do
    DailyMetric
    |> since_date(from_date)
    |> for_project(project_id)
    |> group_by([m], m.date)
    |> select(
      [m],
      {m.date,
       %{
         tokens: type(coalesce(sum(m.total_tokens), 0), :integer),
         cost_cents: type(coalesce(sum(m.cost_cents), 0), :integer)
       }}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp raw_by_date(from_date, project_id) do
    AgentRun
    |> since_datetime(from_date)
    |> runs_for_project(project_id)
    |> group_by([r], fragment("date(?)", r.started_at))
    |> select(
      [r],
      {fragment("date(?)", r.started_at),
       %{
         tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
         cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer)
       }}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp since_date(query, nil), do: query
  defp since_date(query, from_date), do: where(query, [m], m.date >= ^from_date)

  defp since_datetime(query, nil), do: query

  defp since_datetime(query, from_date),
    do: where(query, [r], r.started_at >= ^day_start(from_date))

  # The project filter takes nil (unrestricted), one id, or a list of ids
  # (a non-admin's visible projects).
  defp for_project(query, nil), do: query

  defp for_project(query, project_ids) when is_list(project_ids),
    do: where(query, [m], m.project_id in ^project_ids)

  defp for_project(query, project_id), do: where(query, [m], m.project_id == ^project_id)

  defp runs_for_project(query, nil), do: query

  defp runs_for_project(query, project_ids) when is_list(project_ids),
    do:
      join(query, :inner, [r], t in Task, on: t.id == r.task_id and t.project_id in ^project_ids)

  defp runs_for_project(query, project_id),
    do: join(query, :inner, [r], t in Task, on: t.id == r.task_id and t.project_id == ^project_id)

  defp add_spend(a, b) do
    %{tokens: a.tokens + b.tokens, cost_cents: a.cost_cents + b.cost_cents}
  end

  defp month_start, do: Date.beginning_of_month(Date.utc_today())

  defp today_start, do: day_start(Date.utc_today())

  defp day_start(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
end
