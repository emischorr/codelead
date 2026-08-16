defmodule CodeLead.TerminalTest do
  # async: false — swaps the :terminal_command / :terminal_idle_ms
  # config, and sessions register in the app-global Terminal registry.
  use CodeLead.DataCase, async: false

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Terminal

  @fake_shell Path.expand("../support/fake_shell.sh", __DIR__)

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

  test "a task without a worktree has no terminal" do
    project = project_fixture()
    task = task_fixture(project.id, %{})

    assert Terminal.ensure_session(task) == {:error, :no_worktree}
  end
end
