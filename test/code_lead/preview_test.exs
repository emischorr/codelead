defmodule CodeLead.PreviewTest do
  # async: false — sessions register globally and license grants are
  # process-global.
  use CodeLead.DataCase, async: false

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.LicenseHelpers
  alias CodeLead.OsProcessHelpers
  alias CodeLead.Preview
  alias CodeLead.PreviewGatewayHelpers

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

  # An open port with nobody answering — the shape a preview relay
  # presents when the dev server behind it never bound. Serving is a
  # separate step so a test can start a session first and only then let
  # the port answer.
  defp listener! do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {listener, port}
  end

  # One minimal HTTP response per connection — what the probe now
  # requires before it calls a server ready.
  defp serve!(listener) do
    server = spawn(fn -> serve(listener) end)
    on_exit(fn -> Process.exit(server, :kill) end)
    server
  end

  defp serve(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 1_000)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
        )

        :gen_tcp.close(socket)
        serve(listener)

      {:error, _closed} ->
        :ok
    end
  end

  test "refuses without a declared preview command" do
    task = repo_task(%{preview_port: 5173})

    assert Preview.ensure_session(task) == {:error, :no_preview_command}
  end

  test "refuses without a worktree" do
    task = repo_task(%{preview_port: 5173, preview_command: "sleep 30"})

    assert Preview.ensure_session(task) == {:error, :no_worktree}
  end

  test "refuses without a declared preview port" do
    task =
      repo_task(%{preview_command: "sleep 30"})
      |> put_context!(%{worktree_path: worktree!()})

    assert Preview.ensure_session(task) == {:error, :no_preview_port}
  end

  test "refuses to stack a second server on a port that already answers" do
    {listener, port} = listener!()
    serve!(listener)

    task =
      repo_task(%{preview_port: port, preview_command: "sleep 30"})
      |> put_context!(%{worktree_path: worktree!()})

    assert Preview.ensure_session(task) == {:error, :port_in_use}
  end

  # The relay sidecar accepts on behalf of a dev server that may not be
  # there, so an open port has to count for nothing on its own.
  test "a port that accepts but never answers is not a running server" do
    {_listener, port} = listener!()

    task =
      repo_task(%{preview_port: port, preview_command: "sleep 30"})
      |> put_context!(%{worktree_path: worktree!()})

    assert {:ok, pid} = Preview.ensure_session(task)
    assert Preview.status(task.id) == :starting

    on_exit(fn -> Preview.stop(task.id) end)
    assert is_pid(pid)
  end

  test "a server that stops answering leaves the running state" do
    Application.put_env(:code_lead, :preview_liveness_ms, 100)
    on_exit(fn -> Application.delete_env(:code_lead, :preview_liveness_ms) end)

    {listener, port} = listener!()

    task =
      repo_task(%{preview_port: port, preview_command: "sleep 30"})
      |> put_context!(%{worktree_path: worktree!()})

    :ok = Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")

    # Started against a port that only accepts, so the session is real
    # before anything answers on it.
    assert {:ok, _pid} = Preview.ensure_session(task)
    serve!(listener)
    assert_receive {:preview_state, _task_id, :ready}, 5_000

    :gen_tcp.close(listener)

    assert_receive {:preview_state, _task_id, :unreachable}, 5_000
    assert Preview.status(task.id) == :unreachable

    on_exit(fn -> Preview.stop(task.id) end)
  end

  test "a session started under another gateway is replaced, not reused" do
    task =
      repo_task(%{preview_port: 5173, preview_command: "sleep 30"})
      |> put_context!(%{worktree_path: worktree!()})

    assert {:ok, first} = Preview.ensure_session(task)
    ref = Process.monitor(first)

    PreviewGatewayHelpers.subdomain_gateway!()

    assert {:ok, second} = Preview.ensure_session(task)
    assert second != first
    assert_receive {:DOWN, ^ref, :process, ^first, :normal}, 5_000

    on_exit(fn -> Preview.stop(task.id) end)
  end

  test "a session whose injected env drifted is replaced" do
    task =
      repo_task(%{preview_port: 5173, preview_command: "sleep 30"})
      |> put_context!(%{worktree_path: worktree!()})

    assert {:ok, first} =
             Preview.ensure_session(task, extra_env: [{"PREVIEW_ORIGIN", "http://a"}])

    ref = Process.monitor(first)

    assert {:ok, second} =
             Preview.ensure_session(task, extra_env: [{"PREVIEW_ORIGIN", "http://b"}])

    assert second != first
    assert_receive {:DOWN, ^ref, :process, ^first, :normal}, 5_000

    on_exit(fn -> Preview.stop(task.id) end)
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

  test "stopping a local preview reaps the whole process group, not just the shell" do
    worktree = worktree!()
    child_pid_file = Path.join(worktree, "child.pid")

    # `$!` is a *grandchild* of the port: signalling only the shell's own
    # pid leaves it holding the preview port forever.
    task =
      repo_task(%{
        preview_port: 5173,
        preview_command: "sleep 300 & echo $! > #{child_pid_file}; sleep 300"
      })
      |> put_context!(%{worktree_path: worktree})

    assert {:ok, pid} = Preview.ensure_session(task)
    ref = Process.monitor(pid)

    child_pid = await_recorded_pid(child_pid_file)
    assert OsProcessHelpers.alive?(child_pid)

    assert Preview.stop(task.id) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert OsProcessHelpers.await_gone(child_pid) == :ok
  end

  test "an application shutdown stops the server, not just the port" do
    worktree = worktree!()
    child_pid_file = Path.join(worktree, "child.pid")

    task =
      repo_task(%{
        preview_port: 5173,
        preview_command: "sleep 300 & echo $! > #{child_pid_file}; sleep 300"
      })
      |> put_context!(%{worktree_path: worktree})

    assert {:ok, pid} = Preview.ensure_session(task)
    ref = Process.monitor(pid)
    child_pid = await_recorded_pid(child_pid_file)

    # What the supervisor does on the way down — no :stop call anywhere.
    DynamicSupervisor.terminate_child(CodeLead.Preview.SessionSupervisor, pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    assert OsProcessHelpers.await_gone(child_pid) == :ok
  end

  test "a command that exits leaving background children still gets them reaped" do
    worktree = worktree!()
    child_pid_file = Path.join(worktree, "child.pid")

    # The shell daemonizes a server (stdout detached, or the port would
    # stay open on the child's handle) and exits. Its own pid is gone by
    # the time the session notices, but the group it led is not — and the
    # orphan would otherwise hold the preview port.
    task =
      repo_task(%{
        preview_port: 5173,
        preview_command: "sleep 300 >/dev/null 2>&1 & echo $! > #{child_pid_file}"
      })
      |> put_context!(%{worktree_path: worktree})

    assert {:ok, pid} = Preview.ensure_session(task)
    ref = Process.monitor(pid)
    child_pid = await_recorded_pid(child_pid_file)

    # The session ends on its own: the port reports the shell's exit.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert OsProcessHelpers.await_gone(child_pid) == :ok
  end

  defp await_recorded_pid(path, attempts \\ 80) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> retry_recorded_pid(path, attempts)
          pid -> pid
        end

      {:error, :enoent} ->
        retry_recorded_pid(path, attempts)
    end
  end

  defp retry_recorded_pid(_path, 0), do: flunk("preview command never recorded its child pid")

  defp retry_recorded_pid(path, attempts) do
    Process.sleep(25)
    await_recorded_pid(path, attempts - 1)
  end
end
