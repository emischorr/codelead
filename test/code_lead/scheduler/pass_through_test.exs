defmodule CodeLead.Scheduler.PassThroughTest do
  use CodeLead.DataCase, async: true

  import CodeLead.TasksFixtures

  alias CodeLead.Costs
  alias CodeLead.Projects
  alias CodeLead.Scheduler.PassThrough

  describe "admit?/1 gate composition" do
    test "admits a task with nothing holding it" do
      %{task: task} = runnable_task_fixture()

      assert PassThrough.admit?(task) == :ok
    end

    test "the schedule gate runs before the budget gate" do
      task = over_budget_task()
      at = DateTime.add(DateTime.utc_now(:second), 3600)

      # Both gates would hold. Before the start time the honest answer is
      # the clock — budget can still change before the run happens.
      assert PassThrough.admit?(%{task | scheduled_at: at}) == {:hold, {:scheduled, at}}
    end

    test "budget still holds once the start time has passed" do
      task = over_budget_task()
      at = DateTime.add(DateTime.utc_now(:second), -60)

      assert PassThrough.admit?(%{task | scheduled_at: at}) == {:hold, :budget}
    end
  end

  defp over_budget_task do
    %{task: task, project: project} = runnable_task_fixture()

    {:ok, _project} = Projects.update_project(project, %{budget_limit_cents: 5})

    {:ok, _run} =
      Costs.record_run(%{
        task_id: task.id,
        status: :ok,
        started_at: DateTime.utc_now(:second),
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2, cost_cents: 10}
      })

    task
  end
end
