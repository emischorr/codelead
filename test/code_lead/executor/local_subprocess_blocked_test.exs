defmodule CodeLead.Executor.LocalSubprocessBlockedTest do
  # async: false — swaps the :docker_cli config so the remover's docker
  # escalation stays out of the way and leftovers actually survive.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor.LocalSubprocess
  alias CodeLead.Git
  alias CodeLead.Tasks
  alias CodeLead.Workspace

  setup do
    original = Application.get_env(:code_lead, :docker_cli)
    Application.put_env(:code_lead, :docker_cli, ["definitely-not-docker-xyz"])
    on_exit(fn -> Application.put_env(:code_lead, :docker_cli, original) end)
    :ok
  end

  defp repo_task do
    project = project_fixture()

    repository =
      repository_fixture(project.id, %{git_url: create_origin!(), default_branch: "main"})

    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task_fixture(project.id, %{
      work_type: :code,
      target: :repo,
      repository_id: repository.id,
      agent_id: executor.id
    })
  end

  # A subtree the app's own uid cannot delete — the shape a
  # container-executed agent leaves behind as root.
  defp block!(base) do
    locked = Path.join(base, "locked")
    File.mkdir_p!(locked)
    File.write!(Path.join(locked, "file.txt"), "unremovable")
    File.chmod!(locked, 0o555)

    on_exit(fn ->
      _ = File.chmod(locked, 0o755)
      _ = File.rm_rf(base)
    end)

    locked
  end

  test "teardown keep: false surfaces the leftover; the branch discard still lands" do
    task = repo_task()
    {:ok, context} = LocalSubprocess.provision(task)
    block!(Path.join(context.path, "blocked"))

    assert {:error, {:leftover, leftover}} = LocalSubprocess.teardown(context, keep: false)
    assert leftover == context.path
    assert File.exists?(context.path)

    # The branch delete is independent of the file removal — the discard
    # semantics hold for everything git controls, only files remain.
    {:ok, branches} = Git.git(context.base_clone_path, ["branch", "--list"])
    refute branches =~ context.branch_name
  end

  test "provisioning over an unremovable leftover names the blocked path" do
    task = repo_task()
    worktree_path = Workspace.worktree_path(task.id)

    # Not a worktree of this clone — just a poisoned directory squatting
    # on the task's path, like one left by a failed discard.
    block!(Path.join(worktree_path, "blocked"))

    assert {:error, {:workspace_blocked, ^worktree_path}} =
             LocalSubprocess.provision(Tasks.get_task!(task.id))
  end
end
