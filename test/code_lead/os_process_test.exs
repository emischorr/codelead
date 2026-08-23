defmodule CodeLead.OsProcessTest do
  use ExUnit.Case, async: true

  alias CodeLead.OsProcess
  alias CodeLead.OsProcessHelpers

  describe "terminate_group/1" do
    test "reaches a process the signalled process started" do
      marker = Path.join(System.tmp_dir!(), "os_process_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(marker) end)

      port =
        Port.open(
          {:spawn_executable, "/bin/sh"},
          [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            args: ["-c", "sleep 300 & echo $! > #{marker}; sleep 300"]
          ]
        )

      child_pid = await_marker(marker)
      assert OsProcessHelpers.alive?(child_pid)

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      assert OsProcess.terminate_group(os_pid) == :ok

      assert OsProcessHelpers.await_gone(child_pid) == :ok
      assert OsProcessHelpers.await_gone(os_pid) == :ok
    end

    test "is quiet about a group that is already gone" do
      assert OsProcess.terminate_group(999_999) == :ok
    end
  end

  describe "record_pid_and_exec/2" do
    test "execs through env so a leading VAR=value is an assignment, not the command" do
      script = OsProcess.record_pid_and_exec("PORT=4002 mix phx.server", "/tmp/some.pid")

      assert script =~ ~s(echo $$ > "/tmp/some.pid")
      assert script =~ "exec env PORT=4002 mix phx.server"
    end

    test "applies the assignment and keeps the recorded pid the one that runs" do
      dir = System.tmp_dir!()
      unique = System.unique_integer([:positive])
      marker = Path.join(dir, "record_pid_marker_#{unique}")
      pid_file = Path.join(dir, "record_pid_#{unique}.pid")
      on_exit(fn -> Enum.each([marker, pid_file], &File.rm/1) end)

      command = ~s(PORT=4002 sh -c 'echo "$PORT" > #{marker}; sleep 300')

      port =
        Port.open(
          {:spawn_executable, "/bin/sh"},
          [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            args: ["-lc", OsProcess.record_pid_and_exec(command, pid_file)]
          ]
        )

      # The assignment reached the command rather than being taken for
      # its name (`exec: PORT=4002: not found`).
      assert await_marker(marker) == "4002"

      # And the exec chain preserved pid identity, which is what makes
      # the recorded pid signallable (ADR-0013).
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      assert await_marker(pid_file) == to_string(os_pid)

      assert OsProcess.terminate_group(os_pid) == :ok
      assert OsProcessHelpers.await_gone(os_pid) == :ok
    end
  end

  describe "terminate_group_script/1" do
    test "signals the group first and falls back to the bare pid" do
      script = OsProcess.terminate_group_script("/tmp/some.pid")

      assert script =~ ~s(read -r p < "/tmp/some.pid")
      assert script =~ ~s(kill -TERM -"$p")
      assert script =~ ~s(kill -TERM "$p")
      # A stopper runs inside a terminate path and must never fail it.
      assert String.ends_with?(script, "exit 0")
    end

    test "does nothing when the pid file is missing or empty" do
      missing = Path.join(System.tmp_dir!(), "absent_#{System.unique_integer([:positive])}.pid")

      assert {_output, 0} =
               System.cmd("sh", ["-c", OsProcess.terminate_group_script(missing)],
                 stderr_to_stdout: true
               )
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

  defp retry_marker(_path, 0), do: flunk("shell never recorded its child pid")

  defp retry_marker(path, attempts) do
    Process.sleep(25)
    await_marker(path, attempts - 1)
  end
end
