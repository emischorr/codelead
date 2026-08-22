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

    test "creating a task notifies board subscribers" do
      project = project_fixture()
      :ok = Tasks.subscribe_board(project.id)
      project_id = project.id

      task = task_fixture(project.id)
      task_id = task.id

      assert_receive {:board_changed, ^project_id, ^task_id}
    end

    test "one org subscription covers every project" do
      project_a = project_fixture()
      project_b = project_fixture()
      :ok = Tasks.subscribe_org()
      a_id = project_a.id
      b_id = project_b.id

      task_a = task_fixture(project_a.id)
      task_b = task_fixture(project_b.id)
      a_task_id = task_a.id
      b_task_id = task_b.id

      assert_receive {:board_changed, ^a_id, ^a_task_id}
      assert_receive {:board_changed, ^b_id, ^b_task_id}
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

  describe "titles/1" do
    test "keys titles by id, skipping ids without a task" do
      project = project_fixture()
      task = task_fixture(project.id, %{title: "Add search"})
      gone = System.unique_integer([:positive])

      titles = Tasks.titles([task.id, gone])

      assert titles[task.id] == "Add search"
      # A live session can outlive its task; the caller falls back to
      # the bare id rather than this raising.
      refute Map.has_key?(titles, gone)
    end

    test "asks nothing of the database for an empty list" do
      assert Tasks.titles([]) == %{}
    end
  end
end
