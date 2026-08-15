defmodule Mix.Tasks.CodeLead.Workspace.CleanTest do
  # async: false — swaps the :docker_cli config and the Mix shell.
  use CodeLead.DataCase, async: false

  import CodeLead.TasksFixtures

  alias CodeLead.Workspace

  @fake_docker Path.expand("../../support/fake_docker.sh", __DIR__)
  @per_task_dirs ["worktrees", "tasks", "surveys", "merges", "agent-homes"]

  setup do
    original_cli = Application.get_env(:code_lead, :docker_cli)
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    # A CLI that never resolves keeps the container sweep away from any
    # real daemon unless a test opts into the fake.
    Application.put_env(:code_lead, :docker_cli, ["definitely-not-docker"])

    log = Path.join(System.tmp_dir!(), "fake_docker_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_DOCKER_LOG", log)

    on_exit(fn ->
      Application.put_env(:code_lead, :docker_cli, original_cli)
      Mix.shell(original_shell)
      System.delete_env("FAKE_DOCKER_LOG")
      File.rm(log)
    end)

    %{log: log}
  end

  defp seed_workspace do
    root = Workspace.root()

    for dir <- @per_task_dirs ++ ["repos"] do
      File.mkdir_p!(Path.join([root, dir, "sentinel"]))
    end

    root
  end

  test "refuses when a task has a live run and deletes nothing" do
    %{task: task} = runnable_task_fixture()
    task = executing_task(task)
    root = seed_workspace()

    assert_raise Mix.Error, ~r/live or pending run.*#{task.id}/s, fn ->
      Mix.Tasks.CodeLead.Workspace.Clean.run([])
    end

    for dir <- @per_task_dirs do
      assert File.dir?(Path.join([root, dir, "sentinel"]))
    end
  end

  test "--force cleans despite live runs, keeping repos" do
    %{task: task} = runnable_task_fixture()
    _task = executing_task(task)
    root = seed_workspace()

    Mix.Tasks.CodeLead.Workspace.Clean.run(["--force"])

    for dir <- @per_task_dirs do
      refute File.exists?(Path.join(root, dir))
    end

    assert File.dir?(Path.join([root, "repos", "sentinel"]))
  end

  test "cleans when no run is live" do
    %{task: _task} = runnable_task_fixture()
    root = seed_workspace()

    # A task still in Planning has no run and must not block.
    Mix.Tasks.CodeLead.Workspace.Clean.run([])

    for dir <- @per_task_dirs do
      refute File.exists?(Path.join(root, dir))
    end
  end

  test "a failed run does not block" do
    %{task: task} = runnable_task_fixture()
    task = executing_task(task)
    {:ok, _task} = CodeLead.Tasks.fail_run(task, "boom")
    seed_workspace()

    Mix.Tasks.CodeLead.Workspace.Clean.run([])
  end

  test "sweeps managed containers through the docker CLI", %{log: log} do
    Application.put_env(:code_lead, :docker_cli, ["sh", @fake_docker, "orphans"])
    seed_workspace()

    Mix.Tasks.CodeLead.Workspace.Clean.run([])

    log_output = File.read!(log)
    assert log_output =~ "ps -aq --filter label=codelead.managed=true"
    assert log_output =~ "rm -f abc123"
    assert log_output =~ "rm -f def456"
  end
end
