defmodule CodeLead.TasksBoardEventsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Tasks

  describe "board broadcasts" do
    test "human transitions notify board subscribers" do
      %{task: task, project: project} = runnable_task_fixture()
      :ok = Tasks.subscribe_board(project.id)
      project_id = project.id
      task_id = task.id

      {:ok, task} = Tasks.move_to_running(task)
      assert_receive {:board_changed, ^project_id, ^task_id}

      {:ok, _task} = Tasks.cancel_run(task)
      assert_receive {:board_changed, ^project_id, ^task_id}
    end

    test "system transitions and attention changes notify board subscribers" do
      %{task: task, project: project} = runnable_task_fixture()
      :ok = Tasks.subscribe_board(project.id)
      project_id = project.id
      task_id = task.id

      task = executing_task(task)
      assert_receive {:board_changed, ^project_id, ^task_id}

      {:ok, task} = Tasks.set_attention(task, :agent_question, "which retention window?")
      assert_receive {:board_changed, ^project_id, ^task_id}

      {:ok, _task} = Tasks.clear_attention(task)
      assert_receive {:board_changed, ^project_id, ^task_id}
    end

    test "update_task and archive notify board subscribers" do
      project = project_fixture()
      task = task_fixture(project.id)
      :ok = Tasks.subscribe_board(project.id)
      project_id = project.id
      task_id = task.id

      {:ok, task} = Tasks.update_task(task, %{title: "renamed"})
      assert_receive {:board_changed, ^project_id, ^task_id}

      task = task |> Ecto.Changeset.change(state: :done) |> Repo.update!()
      {:ok, _task} = Tasks.archive(task)
      assert_receive {:board_changed, ^project_id, ^task_id}
    end
  end

  describe "set_attention/4 with ref" do
    test "stores the opaque ref for later answers" do
      project = project_fixture()
      task = task_fixture(project.id)

      {:ok, task} = Tasks.set_attention(task, :permission_request, "write outside", ref: "42")
      assert task.attention.ref == "42"
    end
  end

  describe "commit_notes/1" do
    test "returns the latest commit-step summary per task" do
      project = project_fixture()
      task = task_fixture(project.id)
      other = task_fixture(project.id)

      Tasks.record_step(task.id, :commit, :system, "finalizer", "pushed task/1 · PR ready")
      Tasks.record_step(task.id, :commit, :system, "finalizer", "pushed task/1 · follow-up")

      notes = Tasks.commit_notes([task.id, other.id])

      assert notes[task.id] == "pushed task/1 · follow-up"
      refute Map.has_key?(notes, other.id)
      assert Tasks.commit_notes([]) == %{}
    end
  end
end
