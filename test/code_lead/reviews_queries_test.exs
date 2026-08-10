defmodule CodeLead.ReviewsQueriesTest do
  use CodeLead.DataCase, async: true

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Reviews
  alias CodeLead.Reviews.Review

  defp insert_review!(task_id, cycle, verdict) do
    Repo.insert!(%Review{task_id: task_id, cycle: cycle, verdict: verdict})
  end

  test "verdicts_by_task/1 returns only the latest cycle's verdicts" do
    project = project_fixture()
    task_a = task_fixture(project.id)
    task_b = task_fixture(project.id)
    task_c = task_fixture(project.id)

    insert_review!(task_a.id, 1, :block)
    insert_review!(task_a.id, 2, :pass)
    insert_review!(task_a.id, 2, :concerns)
    insert_review!(task_b.id, 1, nil)

    verdicts = Reviews.verdicts_by_task([task_a.id, task_b.id, task_c.id])

    assert Enum.sort(verdicts[task_a.id]) == [:concerns, :pass]
    assert verdicts[task_b.id] == [nil]
    refute Map.has_key?(verdicts, task_c.id)
    assert Reviews.verdicts_by_task([]) == %{}
  end
end
