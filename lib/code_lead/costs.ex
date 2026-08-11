defmodule CodeLead.Costs do
  @moduledoc """
  Usage/cost capture and budgets. Every run's tokens land in
  `agent_runs` (prunable); a nightly Oban job rolls completed days into
  permanent `daily_metrics`. Spend = rolled-up days + today's raw runs.
  Budgets are cumulative totals (no period) in MVP.
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
  Cumulative spend for a project: permanent rollups plus today's
  not-yet-rolled runs.
  """
  @spec project_spend(pos_integer()) :: spend()
  def project_spend(project_id) do
    rolled =
      Repo.one(
        from m in DailyMetric,
          where: m.project_id == ^project_id,
          select: %{
            tokens: type(coalesce(sum(m.total_tokens), 0), :integer),
            cost_cents: type(coalesce(sum(m.cost_cents), 0), :integer)
          }
      )

    fresh =
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

    add_spend(rolled, fresh)
  end

  @doc """
  Cumulative spend across the organization.
  """
  @spec org_spend() :: spend()
  def org_spend do
    rolled =
      Repo.one(
        from m in DailyMetric,
          select: %{
            tokens: type(coalesce(sum(m.total_tokens), 0), :integer),
            cost_cents: type(coalesce(sum(m.cost_cents), 0), :integer)
          }
      )

    fresh =
      Repo.one(
        from r in AgentRun,
          where: r.started_at >= ^today_start(),
          select: %{
            tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
            cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer)
          }
      )

    add_spend(rolled, fresh)
  end

  @doc """
  Today's not-yet-rolled-up spend across the organization.
  """
  @spec org_spend_today() :: spend()
  def org_spend_today do
    Repo.one(
      from r in AgentRun,
        where: r.started_at >= ^today_start(),
        select: %{
          tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
          cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer)
        }
    )
  end

  @doc """
  Cumulative spend per project — rollups plus today's runs — in two
  queries regardless of how many projects exist. Projects that have
  never spent anything are absent.
  """
  @spec spend_by_project() :: %{pos_integer() => spend()}
  def spend_by_project do
    rolled =
      Repo.all(
        from m in DailyMetric,
          group_by: m.project_id,
          select:
            {m.project_id,
             %{
               tokens: type(coalesce(sum(m.total_tokens), 0), :integer),
               cost_cents: type(coalesce(sum(m.cost_cents), 0), :integer)
             }}
      )
      |> Map.new()

    fresh =
      Repo.all(
        from r in AgentRun,
          join: t in Task,
          on: t.id == r.task_id,
          where: r.started_at >= ^today_start(),
          group_by: t.project_id,
          select:
            {t.project_id,
             %{
               tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
               cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer)
             }}
      )
      |> Map.new()

    Map.merge(rolled, fresh, fn _project_id, a, b -> add_spend(a, b) end)
  end

  @doc """
  Org-wide spend per day for the last `days` days, oldest first, with
  missing days zero-filled — the dashboard's spend chart.
  """
  @spec daily_series(pos_integer()) :: [
          %{
            date: Date.t(),
            tokens: non_neg_integer(),
            cost_cents: non_neg_integer(),
            run_count: non_neg_integer()
          }
        ]
  def daily_series(days) do
    from_date = Date.add(Date.utc_today(), -(days - 1))

    raw =
      Repo.all(
        from r in AgentRun,
          where: r.started_at >= ^DateTime.new!(from_date, ~T[00:00:00], "Etc/UTC"),
          group_by: fragment("date(?)", r.started_at),
          select:
            {fragment("date(?)", r.started_at),
             %{
               tokens: type(coalesce(sum(r.total_tokens), 0), :integer),
               cost_cents: type(coalesce(sum(r.cost_cents), 0), :integer),
               run_count: count(r.id)
             }}
      )
      |> Map.new()

    rolled =
      Repo.all(
        from m in DailyMetric,
          where: m.date >= ^from_date,
          group_by: m.date,
          select:
            {m.date,
             %{
               tokens: type(coalesce(sum(m.total_tokens), 0), :integer),
               cost_cents: type(coalesce(sum(m.cost_cents), 0), :integer),
               run_count: type(coalesce(sum(m.run_count), 0), :integer)
             }}
      )
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
  project's or the organization's cost/token limit is reached.
  """
  @spec check_budget(pos_integer()) :: :ok | {:hold, :budget}
  def check_budget(project_id) do
    project = CodeLead.Projects.get_project!(project_id)
    organization = Accounts.get_organization!()
    project_spend = project_spend(project_id)
    org_spend = org_spend()

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

  defp add_spend(a, b) do
    %{tokens: a.tokens + b.tokens, cost_cents: a.cost_cents + b.cost_cents}
  end

  defp today_start do
    DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
  end
end
