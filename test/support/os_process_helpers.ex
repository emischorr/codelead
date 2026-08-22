defmodule CodeLead.OsProcessHelpers do
  @moduledoc """
  Assertions about OS processes the BEAM spawned. Teardown correctness
  is invisible to `assert_receive` — a leaked child sends nothing — so
  liveness has to be sampled. This is the one place polling is the
  mechanism rather than a synchronization shortcut.
  """

  @doc """
  Blocks until `os_pid` is gone, or returns `{:error, :still_running}`.
  """
  @spec await_gone(String.t() | pos_integer(), timeout()) :: :ok | {:error, :still_running}
  def await_gone(os_pid, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(to_string(os_pid), deadline)
  end

  @doc """
  Whether `os_pid` currently exists, via a signal-less `kill -0`.
  """
  @spec alive?(String.t() | pos_integer()) :: boolean()
  def alive?(os_pid) do
    {_output, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  defp poll(os_pid, deadline) do
    cond do
      not alive?(os_pid) -> :ok
      System.monotonic_time(:millisecond) >= deadline -> {:error, :still_running}
      true -> poll_again(os_pid, deadline)
    end
  end

  defp poll_again(os_pid, deadline) do
    Process.sleep(25)
    poll(os_pid, deadline)
  end
end
