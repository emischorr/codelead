defmodule CodeLead.OsProcessHelpers do
  @moduledoc """
  Assertions about OS processes the BEAM spawned. Teardown correctness
  is invisible to `assert_receive` — a leaked child sends nothing — so
  liveness has to be sampled. This is the one place polling is the
  mechanism rather than a synchronization shortcut.

  A zombie counts as gone: it has already died and only waits for its
  parent (or whoever inherited it) to reap it. `kill -0` still succeeds
  on a zombie, and on Linux hosts where orphans are reparented to a slow
  reaper (GitHub's runner VMs) that made teardown look like a leak.
  Where `/proc` exists the state is read from there; elsewhere (macOS)
  `kill -0` is the fallback.
  """

  @doc """
  Blocks until `os_pid` is gone, or returns `{:error, :still_running}`.
  """
  @spec await_gone(String.t() | pos_integer(), timeout()) ::
          :ok | {:error, :still_running} | {:error, {:still_running, String.t()}}
  def await_gone(os_pid, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(to_string(os_pid), deadline)
  end

  @doc """
  Whether `os_pid` currently exists as a live (non-zombie) process.
  """
  @spec alive?(String.t() | pos_integer()) :: boolean()
  def alive?(os_pid) do
    case proc_state(os_pid) do
      {:ok, state} -> state not in ["Z", "X"]
      :no_proc -> signal_alive?(os_pid)
    end
  end

  defp poll(os_pid, deadline) do
    cond do
      not alive?(os_pid) -> :ok
      System.monotonic_time(:millisecond) >= deadline -> still_running(os_pid)
      true -> poll_again(os_pid, deadline)
    end
  end

  defp poll_again(os_pid, deadline) do
    Process.sleep(25)
    poll(os_pid, deadline)
  end

  # On Linux, say *why* it is still there, so a CI failure explains itself.
  defp still_running(os_pid) do
    case File.read("/proc/#{os_pid}/status") do
      {:ok, status} ->
        details =
          status
          |> String.split("\n")
          |> Enum.filter(&String.match?(&1, ~r/^(Name|State|PPid|SigBlk|SigIgn|SigCgt):/))
          |> Enum.join(" | ")

        {:error, {:still_running, details}}

      {:error, _} ->
        {:error, :still_running}
    end
  end

  # `/proc/<pid>/stat` is "pid (comm) S ..."; comm may contain spaces or
  # parens, so the state is the first field after the last ")".
  defp proc_state(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        [_, rest] = String.split(stat, ~r/\)(?!.*\))/s, parts: 2)
        {:ok, rest |> String.trim_leading() |> String.first()}

      {:error, :enoent} ->
        if File.dir?("/proc/self"), do: {:ok, "X"}, else: :no_proc

      {:error, _} ->
        :no_proc
    end
  end

  defp signal_alive?(os_pid) do
    {_output, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end
end
