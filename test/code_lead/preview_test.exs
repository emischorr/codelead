defmodule CodeLead.PreviewTest do
  # async: false — sessions register globally and license grants are
  # process-global.
  use CodeLead.DataCase, async: false

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.LicenseHelpers
  alias CodeLead.Preview

  setup do
    on_exit(&LicenseHelpers.grant_owner!/0)
    :ok
  end

  defp repo_task(repository_attrs, task_attrs \\ %{}) do
    project = project_fixture()
    repository = repository_fixture(project.id, repository_attrs)

    project.id
    |> task_fixture(Map.merge(%{target: :repo, repository_id: repository.id}, task_attrs))
  end

  defp worktree! do
    dir = Path.join(System.tmp_dir!(), "preview_worktree_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "refuses without a declared preview command" do
    task = repo_task(%{preview_port: 5173})

    assert Preview.ensure_session(task) == {:error, :no_preview_command}
  end

  test "refuses without a worktree" do
    task = repo_task(%{preview_port: 5173, preview_command: "sleep 30"})

    assert Preview.ensure_session(task) == {:error, :no_worktree}
  end

  test "container tasks are gated on the license" do
    task =
      repo_task(%{env_kind: :devcontainer, preview_port: 5173, preview_command: "sleep 30"})
      |> put_context!(%{execution_env: :container, worktree_path: worktree!()})

    LicenseHelpers.grant_community!()

    assert Preview.ensure_session(task) == {:error, :container_unlicensed}
  end

  test "starts, reports, and stops a local preview session" do
    task =
      repo_task(%{preview_port: 5173, preview_command: "sleep 30"})
      |> put_context!(%{worktree_path: worktree!()})

    :ok = Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")

    assert {:ok, pid} = Preview.ensure_session(task)
    assert_receive {:preview_state, _task_id, :starting}, 2_000
    assert Preview.status(task.id) == :starting

    # Idempotent while alive.
    assert Preview.ensure_session(task) == {:ok, pid}

    ref = Process.monitor(pid)
    assert Preview.stop(task.id) == :ok
    assert_receive {:preview_state, _task_id, :stopped}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert Preview.status(task.id) == :stopped
  end
end
