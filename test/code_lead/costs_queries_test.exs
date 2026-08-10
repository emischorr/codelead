defmodule CodeLead.CostsQueriesTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Costs

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

  test "spend_by_task/1 sums runs per task in one query" do
    project = project_fixture()
    task_a = task_fixture(project.id)
    task_b = task_fixture(project.id)
    task_c = task_fixture(project.id)

    record_run!(task_a.id, %{usage: %{total_tokens: 100, cost_cents: 10}})
    record_run!(task_a.id, %{usage: %{total_tokens: 50, cost_cents: 5}})
    record_run!(task_b.id, %{usage: %{total_tokens: 7, cost_cents: 1}})

    spend = Costs.spend_by_task([task_a.id, task_b.id, task_c.id])

    assert spend[task_a.id] == %{tokens: 150, cost_cents: 15}
    assert spend[task_b.id] == %{tokens: 7, cost_cents: 1}
    refute Map.has_key?(spend, task_c.id)
    assert Costs.spend_by_task([]) == %{}
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
