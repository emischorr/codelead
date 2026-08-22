defmodule CodeLead.TerminalTest do
  # async: false — swaps the :terminal_command / :terminal_idle_ms
  # config, and sessions register in the app-global Terminal registry.
  use CodeLead.DataCase, async: false

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.OsProcessHelpers
  alias CodeLead.Terminal
  alias CodeLead.Terminal.Session
  alias CodeLead.Workspace

  @fake_shell Path.expand("../support/fake_shell.sh", __DIR__)
  @fake_shell_bg Path.expand("../support/fake_shell_bg.sh", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :terminal_command)
    original_idle = Application.get_env(:code_lead, :terminal_idle_ms)
    Application.put_env(:code_lead, :terminal_command, ["/bin/sh", @fake_shell])

    worktree =
      Path.join(System.tmp_dir!(), "terminal_worktree_#{System.unique_integer([:positive])}")

    File.mkdir_p!(worktree)

    on_exit(fn ->
      restore_env(:terminal_command, original)
      restore_env(:terminal_idle_ms, original_idle)
      File.rm_rf(worktree)
    end)

    %{worktree: worktree}
  end

  # `put_env(key, nil)` stores a literal nil that would defeat the
  # `get_env` defaults — restore by deleting instead.
  defp restore_env(key, nil), do: Application.delete_env(:code_lead, key)
  defp restore_env(key, value), do: Application.put_env(:code_lead, key, value)

  defp terminal_task(worktree) do
    project = project_fixture()
    repository = repository_fixture(project.id)

    project.id
    |> task_fixture(%{target: :repo, repository_id: repository.id})
    |> put_context!(%{worktree_path: worktree})
  end

  defp stop_session(task_id) do
    case Registry.lookup(CodeLead.Terminal.Registry, task_id) do
      [{pid, _value}] ->
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(CodeLead.Terminal.SessionSupervisor, pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      [] ->
        :ok
    end
  end

  test "starts a shell, streams output, and echoes input back", %{worktree: worktree} do
    task = terminal_task(worktree)
    :ok = Terminal.subscribe(task.id)

    assert {:ok, _pid} = Terminal.ensure_session(task)
    task_id = task.id
    assert_receive {:terminal_data, ^task_id, chunk}, 2_000
    assert chunk =~ "FAKE SHELL READY"

    :ok = Terminal.send_input(task.id, "hi\n")
    assert_receive {:terminal_data, ^task_id, echoed}, 2_000
    assert echoed =~ "echo:hi"

    stop_session(task.id)
  end

  test "reattaching finds the same session and repaints from scrollback", %{worktree: worktree} do
    task = terminal_task(worktree)
    :ok = Terminal.subscribe(task.id)

    assert {:ok, pid} = Terminal.ensure_session(task)
    task_id = task.id
    assert_receive {:terminal_data, ^task_id, _ready}, 2_000

    assert {:ok, ^pid} = Terminal.ensure_session(task)
    assert {:ok, scrollback, false} = Terminal.attach(task.id)
    assert scrollback =~ "FAKE SHELL READY"

    stop_session(task.id)
  end

  test "a shell exit broadcasts the status and ends the session", %{worktree: worktree} do
    task = terminal_task(worktree)
    :ok = Terminal.subscribe(task.id)

    assert {:ok, pid} = Terminal.ensure_session(task)
    ref = Process.monitor(pid)
    task_id = task.id
    assert_receive {:terminal_data, ^task_id, _ready}, 2_000

    :ok = Terminal.send_input(task.id, "exit\n")

    assert_receive {:terminal_exit, ^task_id, 7}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    refute Terminal.alive?(task.id)
  end

  test "a viewer-less session idles out", %{worktree: worktree} do
    Application.put_env(:code_lead, :terminal_idle_ms, 50)
    task = terminal_task(worktree)

    assert {:ok, pid} = Terminal.ensure_session(task)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "an attached viewer holds the session past the idle window", %{worktree: worktree} do
    Application.put_env(:code_lead, :terminal_idle_ms, 50)
    task = terminal_task(worktree)

    assert {:ok, pid} = Terminal.ensure_session(task)
    assert {:ok, _scrollback, _pty?} = Terminal.attach(task.id)

    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 200

    # Detaching the only viewer arms the timer again.
    :ok = Terminal.detach(task.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "a crashed viewer detaches implicitly", %{worktree: worktree} do
    Application.put_env(:code_lead, :terminal_idle_ms, 50)
    task = terminal_task(worktree)

    assert {:ok, pid} = Terminal.ensure_session(task)

    viewer =
      spawn(fn ->
        {:ok, _scrollback, _pty?} = Terminal.attach(task.id)

        receive do
          :done -> :ok
        end
      end)

    ref = Process.monitor(pid)
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 200

    Process.exit(viewer, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "a task without an execution context has no terminal" do
    project = project_fixture()
    task = task_fixture(project.id, %{})

    assert Terminal.context_path(task) == nil
    assert Terminal.ensure_session(task) == {:error, :no_context}
  end

  describe "folder-target tasks" do
    setup do
      project = project_fixture()
      task = task_fixture(project.id, %{target: :folder})
      folder = Workspace.task_folder(task.id)

      on_exit(fn -> File.rm_rf(folder) end)

      %{task: task, folder: folder}
    end

    test "have no context until a run provisions the folder", %{task: task} do
      assert Terminal.context_path(task) == nil
      assert Terminal.ensure_session(task) == {:error, :no_context}
    end

    test "get a shell in the task folder once it exists", %{task: task, folder: folder} do
      File.mkdir_p!(folder)

      assert Terminal.context_path(task) == folder

      :ok = Terminal.subscribe(task.id)
      assert {:ok, _pid} = Terminal.ensure_session(task)

      task_id = task.id
      assert_receive {:terminal_data, ^task_id, chunk}, 2_000
      assert chunk =~ "FAKE SHELL READY"

      stop_session(task.id)
    end
  end

  describe "resize/3" do
    test "forwards the new size to the session's resizer" do
      test_pid = self()
      task_id = System.unique_integer([:positive])

      start_resizable_session(task_id, true, fn cols, rows ->
        send(test_pid, {:resized, cols, rows})
      end)

      assert Terminal.resize(task_id, 132, 45) == :ok
      assert_receive {:resized, 132, 45}, 2_000
    end

    test "is ignored by a session without a PTY, where there is no device to resize" do
      test_pid = self()
      task_id = System.unique_integer([:positive])

      pid =
        start_resizable_session(task_id, false, fn cols, rows ->
          send(test_pid, {:resized, cols, rows})
        end)

      assert Terminal.resize(task_id, 132, 45) == :ok
      _ = :sys.get_state(pid)
      refute_received {:resized, _cols, _rows}
    end

    test "is a no-op for a task with no live session" do
      assert Terminal.resize(System.unique_integer([:positive]), 132, 45) == :ok
    end
  end

  describe "stop/1" do
    test "reaps what the shell started, not just the shell", %{worktree: worktree} do
      Application.put_env(:code_lead, :terminal_command, ["/bin/sh", @fake_shell_bg])
      marker = Path.join(worktree, "child.pid")
      task = terminal_task(worktree)

      assert {:ok, pid} =
               Terminal.ensure_session(task,
                 extra_env: [{"CODELEAD_MARKER_FILE", marker}]
               )

      ref = Process.monitor(pid)
      child_pid = await_marker(marker)
      assert OsProcessHelpers.alive?(child_pid)

      assert Terminal.stop(task.id) == :ok
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute Terminal.alive?(task.id)
      assert OsProcessHelpers.await_gone(child_pid) == :ok
    end

    test "is a no-op without a session" do
      assert Terminal.stop(System.unique_integer([:positive])) == :ok
    end

    test "an application shutdown reaps the shell's children too", %{worktree: worktree} do
      Application.put_env(:code_lead, :terminal_command, ["/bin/sh", @fake_shell_bg])
      marker = Path.join(worktree, "child.pid")
      task = terminal_task(worktree)

      assert {:ok, pid} =
               Terminal.ensure_session(task,
                 extra_env: [{"CODELEAD_MARKER_FILE", marker}]
               )

      ref = Process.monitor(pid)
      child_pid = await_marker(marker)

      DynamicSupervisor.terminate_child(CodeLead.Terminal.SessionSupervisor, pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
      assert OsProcessHelpers.await_gone(child_pid) == :ok
    end
  end

  defp await_marker(path, attempts \\ 80) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> retry_marker(path, attempts)
          pid -> pid
        end

      {:error, :enoent} ->
        retry_marker(path, attempts)
    end
  end

  defp retry_marker(_path, 0), do: flunk("fake shell never recorded its child pid")

  defp retry_marker(path, attempts) do
    Process.sleep(25)
    await_marker(path, attempts - 1)
  end

  defp start_resizable_session(task_id, pty?, resizer) do
    start_supervised!(
      {Session,
       %{
         task_id: task_id,
         pty?: pty?,
         port_opener: fn ->
           Port.open(
             {:spawn_executable, "/bin/sh"},
             [:binary, :exit_status, :hide, :stderr_to_stdout, args: [@fake_shell]]
           )
         end,
         stopper: fn _port -> :ok end,
         resizer: resizer
       }}
    )
  end
end
