defmodule CodeLead.Runtime.SendBackCleanupTest do
  # async: false — swaps the :docker_cli config so the remover's docker
  # escalation stays out of the way and the leftover actually survives.
  use CodeLead.DataCase, async: false

  import Ecto.Query

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor.LocalSubprocess
  alias CodeLead.Runtime
  alias CodeLead.Tasks
  alias CodeLead.Tasks.TaskStep

  setup do
    original = Application.get_env(:code_lead, :docker_cli)
    Application.put_env(:code_lead, :docker_cli, ["definitely-not-docker-xyz"])
    on_exit(fn -> Application.put_env(:code_lead, :docker_cli, original) end)
    :ok
  end

  test "send-back still transitions when the worktree survives, and says so" do
    project = project_fixture()

    repository =
      repository_fixture(project.id, %{git_url: create_origin!(), default_branch: "main"})

    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      task_fixture(project.id, %{
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: executor.id
      })

    {:ok, context} = LocalSubprocess.provision(task)
    task = task.id |> Tasks.get_task!() |> executing_task("sess-x")
    {:ok, task} = Tasks.complete_run(task)

    # A subtree the app's own uid cannot delete — what a
    # container-executed agent leaves behind as root.
    locked = Path.join([context.path, "blocked", "locked"])
    File.mkdir_p!(locked)
    File.write!(Path.join(locked, "file.txt"), "unremovable")
    File.chmod!(locked, 0o555)

    on_exit(fn ->
      _ = File.chmod(locked, 0o755)
      _ = File.rm_rf(context.path)
    end)

    worktree = context.path

    assert {:ok, task, {:cleanup_failed, {:leftover, ^worktree}}} =
             Runtime.send_back_to_planning(task)

    # The human's decision stands: the task moved and forgot the context.
    assert task.state == :planning
    assert task.worktree_path == nil
    assert task.branch_name == nil
    assert File.exists?(worktree)

    # The leftover is on the task's record, not just in a log.
    note =
      Repo.one(
        from s in TaskStep,
          where: s.task_id == ^task.id and s.kind == :transition,
          order_by: [desc: s.id],
          limit: 1,
          select: s.summary
      )

    assert note =~ "could not be removed"
    assert note =~ worktree
  end

  test "a clean send-back keeps the plain two-tuple" do
    project = project_fixture()

    repository =
      repository_fixture(project.id, %{git_url: create_origin!(), default_branch: "main"})

    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      task_fixture(project.id, %{
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: executor.id
      })

    {:ok, context} = LocalSubprocess.provision(task)
    task = task.id |> Tasks.get_task!() |> executing_task("sess-x")
    {:ok, task} = Tasks.complete_run(task)

    assert {:ok, task} = Runtime.send_back_to_planning(task)
    assert task.state == :planning
    refute File.exists?(context.path)
  end
end
