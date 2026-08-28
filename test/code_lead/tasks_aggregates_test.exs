defmodule CodeLead.TasksAggregatesTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Tasks

  defp completed!(task, days_ago, lead_hours) do
    completed_at = DateTime.add(DateTime.utc_now(:second), -days_ago * 24 * 3600, :second)

    put_context!(task,
      state: :done,
      completed_at: completed_at,
      inserted_at: DateTime.add(completed_at, -lead_hours * 3600, :second)
    )
  end

  describe "board_summary/0" do
    test "counts every column and run state across projects" do
      project_a = project_fixture()
      project_b = project_fixture()

      task_fixture(project_a.id)
      task_fixture(project_b.id)
      put_context!(task_fixture(project_a.id), state: :running, run_state: :failed)
      put_context!(task_fixture(project_a.id), state: :running, run_state: :executing)
      put_context!(task_fixture(project_b.id), state: :running, run_state: :queued)
      put_context!(task_fixture(project_b.id), state: :review)
      completed!(task_fixture(project_b.id), 1, 4)

      summary = Tasks.board_summary()

      assert summary.planning == 2
      assert summary.running == 3
      assert summary.review == 1
      assert summary.done == 1
      assert summary.failed == 1
      assert summary.executing == 1
      assert summary.queued == 1
    end

    test "ignores archived and cancelled tasks" do
      project = project_fixture()

      task_fixture(project.id)
      put_context!(task_fixture(project.id), state: :cancelled)

      task_fixture(project.id)
      |> completed!(1, 2)
      |> put_context!(archived_at: DateTime.utc_now(:second))

      assert %{planning: 1, done: 0} = Tasks.board_summary()
    end

    test "counts tasks waiting on a human" do
      project = project_fixture()
      task = put_context!(task_fixture(project.id), state: :review)
      {:ok, _task} = Tasks.set_attention(task, :review_ready, "2 reviewers finished")

      assert Tasks.board_summary().attention == 1
    end
  end

  describe "attention_counts/0" do
    # The embed is stored as jsonb with string keys; a mistake in the
    # `->>'type'` grouping reads as zero rather than raising, so this
    # asserts on two distinct types.
    test "groups by attention type across projects" do
      project_a = project_fixture()
      project_b = project_fixture()

      {:ok, _} = Tasks.set_attention(task_fixture(project_a.id), :run_failed, "exit 1")
      {:ok, _} = Tasks.set_attention(task_fixture(project_b.id), :run_failed, "exit 2")
      {:ok, _} = Tasks.set_attention(task_fixture(project_b.id), :agent_question, "which port?")

      assert Tasks.attention_counts() == %{run_failed: 2, agent_question: 1}
    end

    test "ignores archived tasks" do
      project = project_fixture()
      {:ok, task} = Tasks.set_attention(task_fixture(project.id), :run_failed, "exit 1")
      put_context!(task, archived_at: DateTime.utc_now(:second))

      assert Tasks.attention_counts() == %{}
    end
  end

  describe "org_attention_tasks/1" do
    test "returns the oldest first, across projects, honoring the limit" do
      project_a = project_fixture()
      project_b = project_fixture()

      {:ok, first} = Tasks.set_attention(task_fixture(project_a.id), :run_failed, "exit 1")
      first = put_context!(first, updated_at: DateTime.add(DateTime.utc_now(:second), -3, :hour))

      {:ok, second} = Tasks.set_attention(task_fixture(project_b.id), :agent_question, "port?")
      {:ok, _third} = Tasks.set_attention(task_fixture(project_b.id), :run_failed, "exit 2")

      assert [oldest, next] = Tasks.org_attention_tasks(2)
      assert oldest.id == first.id
      assert oldest.project_id == project_a.id
      assert oldest.attention.type == :run_failed
      assert oldest.attention.detail == "exit 1"
      assert next.id == second.id
    end
  end

  describe "active_runs/0" do
    test "lists non-idle running tasks with their agent" do
      project = project_fixture()
      agent = agent_fixture(%{name: "Judy", driver: :acp, harness: :claude_code})

      running =
        put_context!(task_fixture(project.id),
          state: :running,
          run_state: :executing,
          agent_id: agent.id
        )

      task_fixture(project.id)
      put_context!(task_fixture(project.id), state: :running, run_state: :idle)

      assert [run] = Tasks.active_runs()
      assert run.id == running.id
      assert run.run_state == :executing
      assert run.agent_name == "Judy"
      assert run.harness == :claude_code
    end
  end

  describe "completions_by_day/1" do
    test "buckets completions by date and includes archived tasks" do
      project = project_fixture()
      today = Date.utc_today()

      completed!(task_fixture(project.id), 0, 2)
      completed!(task_fixture(project.id), 3, 2)

      task_fixture(project.id)
      |> completed!(3, 2)
      |> put_context!(archived_at: DateTime.utc_now(:second))

      by_day = Tasks.completions_by_day(14)

      assert by_day[today] == 1
      assert by_day[Date.add(today, -3)] == 2
    end

    test "excludes completions outside the window" do
      project = project_fixture()
      completed!(task_fixture(project.id), 20, 2)

      assert Tasks.completions_by_day(14) == %{}
    end
  end

  describe "avg_lead_time_ms/1" do
    test "averages creation-to-approval across completed tasks" do
      project = project_fixture()
      completed!(task_fixture(project.id), 1, 2)
      completed!(task_fixture(project.id), 2, 4)

      assert Tasks.avg_lead_time_ms(14) == 3 * 3600 * 1000
    end

    test "is nil when nothing completed in the window" do
      project = project_fixture()
      task_fixture(project.id)

      assert Tasks.avg_lead_time_ms(14) == nil
    end
  end

  describe "avg_cycle_time_ms/1" do
    test "averages first-Running-to-approval across completed tasks" do
      project = project_fixture()

      task_a = completed!(task_fixture(project.id), 1, 2)
      entered_a = DateTime.add(task_a.completed_at, -3600, :second)
      put_state_transition!(task_a, :planning, :running, entered_a)

      task_b = completed!(task_fixture(project.id), 2, 4)
      entered_b = DateTime.add(task_b.completed_at, -3 * 3600, :second)
      put_state_transition!(task_b, :planning, :running, entered_b)

      assert Tasks.avg_cycle_time_ms(14) == 2 * 3600 * 1000
    end

    test "uses the first entry into Running, not a later rework re-entry" do
      project = project_fixture()
      task = completed!(task_fixture(project.id), 1, 2)

      first_entry = DateTime.add(task.completed_at, -5 * 3600, :second)
      rework_entry = DateTime.add(task.completed_at, -3600, :second)

      put_state_transition!(task, :planning, :running, first_entry)
      put_state_transition!(task, :review, :running, rework_entry)

      assert Tasks.avg_cycle_time_ms(14) == 5 * 3600 * 1000
    end

    test "is nil when nothing completed in the window" do
      project = project_fixture()
      task_fixture(project.id)

      assert Tasks.avg_cycle_time_ms(14) == nil
    end

    test "excludes a completed task with no logged Running entry" do
      project = project_fixture()
      completed!(task_fixture(project.id), 1, 2)

      assert Tasks.avg_cycle_time_ms(14) == nil
    end
  end

  describe "recently_completed/1" do
    test "returns the newest completions first, honoring the limit" do
      project = project_fixture()
      newest = completed!(task_fixture(project.id), 1, 2)
      middle = completed!(task_fixture(project.id), 3, 2)
      _oldest = completed!(task_fixture(project.id), 5, 2)

      assert [first, second] = Tasks.recently_completed(2)
      assert first.id == newest.id
      assert first.project_id == project.id
      assert second.id == middle.id
    end
  end

  describe "recent_activity/1" do
    test "returns the newest steps first with their task and project" do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Ship it"})

      Tasks.record_step(task.id, :transition, :human, "human", "moved to Running (queued)")
      Tasks.record_step(task.id, :run, :agent, "Judy", "run completed")

      assert [newest, older] = Tasks.recent_activity(5)
      assert newest.summary == "run completed"
      assert newest.executor_type == :agent
      assert newest.task_title == "Ship it"
      assert newest.project_id == project.id
      assert older.kind == :transition
    end
  end

  describe "project_summaries/0" do
    test "splits the counts per project and omits projects without tasks" do
      project_a = project_fixture()
      project_b = project_fixture()
      empty_project = project_fixture()

      task_fixture(project_a.id)
      put_context!(task_fixture(project_a.id), state: :review)
      {:ok, _} = Tasks.set_attention(task_fixture(project_b.id), :run_failed, "exit 1")

      summaries = Tasks.project_summaries()

      assert %{planning: 1, review: 1, attention: 0} = summaries[project_a.id]
      assert %{planning: 1, attention: 1} = summaries[project_b.id]
      refute Map.has_key?(summaries, empty_project.id)
    end
  end
end
