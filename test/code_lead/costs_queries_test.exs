defmodule CodeLead.CostsQueriesTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Costs
  alias CodeLead.Costs.DailyMetric
  alias CodeLead.Repo

  defp record_run!(task_id, attrs) do
    {:ok, run} =
      Costs.record_run(
        Map.merge(
          %{
            task_id: task_id,
            status: :ok,
            started_at: DateTime.utc_now(:second),
            finished_at: DateTime.utc_now(:second)
          },
          attrs
        )
      )

    run
  end

  defp insert_metric!(project_id, date, tokens, cost_cents) do
    Repo.insert!(%DailyMetric{
      project_id: project_id,
      date: date,
      total_tokens: tokens,
      cost_cents: cost_cents,
      run_count: 1
    })
  end

  test "spend_by_task/1 sums runs per task in one query" do
    project = project_fixture()
    task_a = task_fixture(project.id)
    task_b = task_fixture(project.id)
    task_c = task_fixture(project.id)

    record_run!(task_a.id, %{usage: %{total_tokens: 100, cost_cents: 10}})
    record_run!(task_a.id, %{usage: %{total_tokens: 50, cost_cents: 5}})
    record_run!(task_b.id, %{usage: %{total_tokens: 7, cost_cents: 1}})

    spend = Costs.spend_by_task([task_a.id, task_b.id, task_c.id])

    assert %{tokens: 150, cost_cents: 15, duration_ms: 0, provider_kinds: []} = spend[task_a.id]
    assert %{tokens: 7, cost_cents: 1} = spend[task_b.id]
    refute Map.has_key?(spend, task_c.id)
    assert Costs.spend_by_task([]) == %{}
  end

  # array_agg bypasses Ecto's enum casting, so the kinds come back as the
  # raw column strings — Agents.billing_mode/1 has to cope with those.
  test "spend_by_task/1 reports the provider kinds behind a task's runs" do
    project = project_fixture()
    task = task_fixture(project.id)

    {:ok, provider} =
      CodeLead.Agents.create_provider(%{
        name: "Sub #{System.unique_integer([:positive])}",
        kind: :anthropic_subscription,
        config: %{"oauth_token" => "t"}
      })

    record_run!(task.id, %{
      provider_id: provider.id,
      duration_ms: 2_500,
      usage: %{total_tokens: 10, cost_cents: 1}
    })

    spend = Costs.spend_by_task([task.id])

    assert spend[task.id].duration_ms == 2_500
    assert spend[task.id].provider_kinds == ["anthropic_subscription"]
    assert CodeLead.Agents.billing_mode(spend[task.id].provider_kinds) == :estimated
  end

  test "project_spend_today/1 counts only today's runs for the project" do
    project = project_fixture()
    task = task_fixture(project.id)

    record_run!(task.id, %{usage: %{total_tokens: 40, cost_cents: 4}})

    record_run!(task.id, %{
      usage: %{total_tokens: 999, cost_cents: 99},
      started_at: DateTime.add(DateTime.utc_now(:second), -2, :day)
    })

    assert Costs.project_spend_today(project.id) == %{tokens: 40, cost_cents: 4}
  end

  test "org_spend_today/0 sums today's runs across projects" do
    task_a = task_fixture(project_fixture().id)
    task_b = task_fixture(project_fixture().id)

    record_run!(task_a.id, %{usage: %{total_tokens: 40, cost_cents: 4}})
    record_run!(task_b.id, %{usage: %{total_tokens: 60, cost_cents: 6}})

    record_run!(task_b.id, %{
      usage: %{total_tokens: 999, cost_cents: 99},
      started_at: DateTime.add(DateTime.utc_now(:second), -2, :day)
    })

    assert Costs.org_spend_today() == %{tokens: 100, cost_cents: 10}
  end

  test "spend_by_project_month/1 merges rollups with raw runs per project, inside the window" do
    project_a = project_fixture()
    project_b = project_fixture()
    quiet_project = project_fixture()

    record_run!(task_fixture(project_a.id).id, %{usage: %{total_tokens: 40, cost_cents: 4}})
    record_run!(task_fixture(project_b.id).id, %{usage: %{total_tokens: 7, cost_cents: 1}})

    insert_metric!(project_a.id, Date.add(Date.utc_today(), -3), 100, 10)
    insert_metric!(project_a.id, Date.add(Date.utc_today(), -40), 999, 99)

    spend = Costs.spend_by_project_month(Date.add(Date.utc_today(), -30))

    assert spend[project_a.id] == %{tokens: 140, cost_cents: 14}
    assert spend[project_b.id] == %{tokens: 7, cost_cents: 1}
    refute Map.has_key?(spend, quiet_project.id)
  end

  # The regression the budget tile showed: assuming every day before today
  # is already rolled up drops each completed day the nightly job has not
  # reached yet — which, run locally, is all of them.
  test "project_spend_month/2 counts completed days the rollup has not reached" do
    project = project_fixture()
    task = task_fixture(project.id)

    record_run!(task.id, %{usage: %{total_tokens: 40, cost_cents: 4}})

    record_run!(task.id, %{
      usage: %{total_tokens: 25, cost_cents: 3},
      started_at: DateTime.add(DateTime.utc_now(:second), -2, :day)
    })

    assert Costs.project_spend_month(project.id, Date.add(Date.utc_today(), -30)) ==
             %{tokens: 65, cost_cents: 7}
  end

  test "project_spend_month/2 ignores spend before the window" do
    project = project_fixture()
    task = task_fixture(project.id)

    record_run!(task.id, %{usage: %{total_tokens: 40, cost_cents: 4}})

    record_run!(task.id, %{
      usage: %{total_tokens: 999, cost_cents: 99},
      started_at: DateTime.add(DateTime.utc_now(:second), -10, :day)
    })

    insert_metric!(project.id, Date.add(Date.utc_today(), -10), 999, 99)

    assert Costs.project_spend_month(project.id, Date.add(Date.utc_today(), -3)) ==
             %{tokens: 40, cost_cents: 4}
  end

  test "project_spend_month/2 counts a day present in both tables once" do
    project = project_fixture()
    task = task_fixture(project.id)
    yesterday = Date.add(Date.utc_today(), -1)

    record_run!(task.id, %{
      usage: %{total_tokens: 100, cost_cents: 10},
      started_at: DateTime.add(DateTime.utc_now(:second), -1, :day)
    })

    insert_metric!(project.id, yesterday, 100, 10)

    assert Costs.project_spend_month(project.id, Date.add(Date.utc_today(), -30)) ==
             %{tokens: 100, cost_cents: 10}
  end

  test "project_spend_month/1 defaults to the calendar month and counts today" do
    project = project_fixture()
    task = task_fixture(project.id)

    record_run!(task.id, %{usage: %{total_tokens: 40, cost_cents: 4}})
    insert_metric!(project.id, Date.add(Date.beginning_of_month(Date.utc_today()), -1), 999, 99)

    assert Costs.project_spend_month(project.id) == %{tokens: 40, cost_cents: 4}
  end

  test "org_spend_month/1 sums the window across projects" do
    project_a = project_fixture()
    project_b = project_fixture()

    record_run!(task_fixture(project_a.id).id, %{usage: %{total_tokens: 40, cost_cents: 4}})
    record_run!(task_fixture(project_b.id).id, %{usage: %{total_tokens: 60, cost_cents: 6}})

    insert_metric!(project_a.id, Date.add(Date.utc_today(), -3), 100, 10)
    insert_metric!(project_b.id, Date.add(Date.utc_today(), -40), 999, 99)

    assert Costs.org_spend_month(Date.add(Date.utc_today(), -30)) ==
             %{tokens: 200, cost_cents: 20}
  end

  test "daily_series/1 returns one zero-filled entry per day, oldest first" do
    task = task_fixture(project_fixture().id)
    today = Date.utc_today()

    record_run!(task.id, %{usage: %{total_tokens: 40, cost_cents: 4}})

    record_run!(task.id, %{
      usage: %{total_tokens: 25, cost_cents: 3},
      started_at: DateTime.add(DateTime.utc_now(:second), -2, :day)
    })

    series = Costs.daily_series(7)

    assert length(series) == 7
    assert List.first(series).date == Date.add(today, -6)
    assert List.last(series).date == today
    assert List.last(series) == %{date: today, tokens: 40, cost_cents: 4, run_count: 1}
    assert Enum.find(series, &(&1.date == Date.add(today, -2))).tokens == 25
    assert Enum.find(series, &(&1.date == Date.add(today, -1))).tokens == 0
  end

  # Between the nightly rollup and the 14-day prune a completed day exists
  # in both tables — `rollup/0` wrote the metric from those very runs, so
  # summing the two sources doubles the day.
  test "daily_series/1 prefers the rollup over raw runs for the same day" do
    project = project_fixture()
    task = task_fixture(project.id)
    yesterday = Date.add(Date.utc_today(), -1)

    record_run!(task.id, %{
      usage: %{total_tokens: 100, cost_cents: 10},
      started_at: DateTime.add(DateTime.utc_now(:second), -1, :day)
    })

    Repo.insert!(%DailyMetric{
      project_id: project.id,
      date: yesterday,
      total_tokens: 100,
      cost_cents: 10,
      run_count: 1
    })

    entry = Costs.daily_series(7) |> Enum.find(&(&1.date == yesterday))

    assert entry == %{date: yesterday, tokens: 100, cost_cents: 10, run_count: 1}
  end

  test "task_runs/1 lists runs newest first with the agent name" do
    project = project_fixture()
    task = task_fixture(project.id)
    agent = agent_fixture(%{name: "Judy"})

    record_run!(task.id, %{
      agent_id: agent.id,
      usage: %{total_tokens: 10, cost_cents: 2},
      started_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
    })

    record_run!(task.id, %{usage: %{total_tokens: 20, cost_cents: 3}})

    assert [newest, oldest] = Costs.task_runs(task.id)
    assert newest.total_tokens == 20
    assert newest.agent_name == nil
    assert oldest.agent_name == "Judy"
    assert oldest.cost_cents == 2
  end
end
