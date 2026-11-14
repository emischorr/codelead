# TEMP — CI diagnostic for the process-group kill failing on GitHub's
# runner (see ci.yml). Remove together with the "kill probe" step.

defmodule KillProbe do
  def stat(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, s} ->
        [_, rest] = String.split(s, ~r/\)(?!.*\))/s, parts: 2)
        [state, ppid, pgrp, sid | _] = String.split(rest)
        "pid=#{pid} state=#{state} ppid=#{ppid} pgrp=#{pgrp} sid=#{sid}"

      _ ->
        "pid=#{pid} gone"
    end
  end

  def spawn_tree(label) do
    marker = Path.join(System.tmp_dir!(), "kill_probe_#{label}")
    File.rm(marker)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", "sleep 300 & echo $! > #{marker}; sleep 300"]
      ])

    child = await(marker, 80)
    {:os_pid, os} = Port.info(port, :os_pid)
    IO.puts("[#{label}] beam=#{stat(System.pid())}")
    IO.puts("[#{label}] sh   #{stat(os)}")
    IO.puts("[#{label}] bg   #{stat(child)}")
    {os, child}
  end

  def attempt(label, fun) do
    {os, child} = spawn_tree(label)

    result =
      try do
        fun.(os)
      rescue
        e -> {:raised, Exception.format(:error, e, __STACKTRACE__)}
      end

    IO.puts("[#{label}] result: #{inspect(result)}")
    Process.sleep(500)
    IO.puts("[#{label}] after sh   #{stat(os)}")
    IO.puts("[#{label}] after bg   #{stat(child)}")
  end

  defp await(path, 0), do: raise("no marker at #{path}")

  defp await(path, n) do
    case File.read(path) do
      {:ok, c} when c != "" -> String.trim(c)
      _ -> Process.sleep(25) && await(path, n - 1)
    end
  end
end

IO.puts("find_executable(kill) = #{inspect(System.find_executable("kill"))}")

KillProbe.attempt("system_cmd_kill", fn os ->
  System.cmd("kill", ["-TERM", "-#{os}"], stderr_to_stdout: true)
end)

KillProbe.attempt("system_cmd_kill_bare", fn os ->
  System.cmd("kill", ["-TERM", "#{os}"], stderr_to_stdout: true)
end)

KillProbe.attempt("sh_builtin", fn os ->
  System.cmd("sh", ["-c", "kill -TERM -#{os}"], stderr_to_stdout: true)
end)

KillProbe.attempt("os_cmd", fn os ->
  :os.cmd(~c"kill -TERM -#{os}; echo exit=$?")
end)
