defmodule CodeLead.OsProcess do
  @moduledoc """
  Signalling OS processes the BEAM spawned but cannot stop by itself.

  Closing a Port does not kill the program behind it — it closes the
  pipes, and the child outlives both the close and the VM. What makes a
  clean stop possible is that port children are process-group leaders
  (`erl_child_setup` calls `setpgid` per child), so everything a spawned
  shell starts inherits its group and a single signal to the group
  reaches the whole tree.

  Pure and stateless, like `CodeLead.Terminal.Command`: one function
  signals from the host, the others build the equivalent shell snippets
  for processes reachable only through `docker exec` — the two ends of
  the pid-file contract, writing it and reading it back.
  """

  @doc """
  Sends SIGTERM to the process group led by `os_pid`, falling back to the
  bare pid when the group is gone or the platform refuses it.
  """
  @spec terminate_group(pos_integer()) :: :ok
  def terminate_group(os_pid) do
    case System.cmd("kill", ["-TERM", "-#{os_pid}"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _no_such_group -> terminate_pid(os_pid)
    end
  rescue
    # `kill(1)` missing is not a reason to fail a teardown.
    _cannot_signal -> :ok
  end

  @doc """
  Shell snippet that records the pid the process behind `command` keeps
  and then hands the shell over to it.
  """
  @spec record_pid_and_exec(String.t(), String.t()) :: String.t()
  def record_pid_and_exec(command, pid_file) do
    # `exec env` rather than a bare `exec`: `exec` is a special builtin,
    # so a leading `VAR=value` after it is taken as the command name
    # (`exec: PORT=4002: not found`). `env` applies the assignments and
    # execs the utility, so the pid `$$` just recorded is still the one
    # the server ends up holding.
    ~s(echo $$ > "#{pid_file}"; exec env #{command})
  end

  @doc """
  Shell snippet that TERMs the process group recorded in `pid_file`.
  For contexts the BEAM cannot signal into, where the pid travels
  through a file the spawned command wrote itself.
  """
  @spec terminate_group_script(String.t()) :: String.t()
  def terminate_group_script(pid_file) do
    # Group first, bare pid second: busybox `kill` may reject a negative
    # pid, and `runc exec` does not always give the exec'd process a
    # group of its own. `exit 0` throughout — a stopper runs inside a
    # terminate path and must never report failure into it.
    ~s(p=""; read -r p < "#{pid_file}" 2>/dev/null; ) <>
      ~s([ -n "$p" ] && { kill -TERM -"$p" 2>/dev/null || ) <>
      ~s(kill -TERM "$p" 2>/dev/null; }; exit 0)
  end

  defp terminate_pid(os_pid) do
    _ = System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end
end
