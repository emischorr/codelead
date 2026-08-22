defmodule CodeLead.Executor.DockerCli do
  @moduledoc """
  Thin transport to the docker CLI for the container executor. The argv
  prefix comes from the `:docker_cli` config key so tests can swap in a
  fake, mirroring the `:harnesses` pattern. Lifecycle commands run via
  `System.cmd/3`; the agent process itself is opened as a Port by
  `CodeLead.Executor.Devcontainer.spawn/3` using `cli/0`.
  """

  @doc """
  The resolved CLI executable and the remaining argv prefix, or an error
  when the configured head is not on the server's PATH.
  """
  @spec cli() :: {:ok, {String.t(), [String.t()]}} | {:error, :docker_cli_not_found}
  def cli do
    [head | prefix] = Application.get_env(:code_lead, :docker_cli, ["docker"])

    case System.find_executable(head) do
      nil -> {:error, :docker_cli_not_found}
      resolved -> {:ok, {resolved, prefix}}
    end
  end

  @spec available?() :: boolean()
  def available?, do: match?({:ok, _resolved}, cli())

  @doc """
  Runs a docker command, merging stderr into the returned output — these
  are lifecycle commands, not protocol traffic. `:timeout` (default
  `:infinity`) bounds a wedged daemon for callers running under a
  supervisor shutdown budget; it bounds the *wait*, not the CLI child,
  which keeps running after the timeout like any other port program.
  """
  @spec run([String.t()], keyword()) ::
          {:ok, String.t()}
          | {:error, {:docker, non_neg_integer(), String.t()} | :docker_cli_not_found | :timeout}
  def run(args, opts \\ []) do
    with {:ok, {path, prefix}} <- cli() do
      case Keyword.get(opts, :timeout, :infinity) do
        :infinity -> exec(path, prefix ++ args)
        timeout -> exec_bounded(path, prefix ++ args, timeout)
      end
    end
  end

  defp exec(path, args) do
    case System.cmd(path, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:docker, status, output}}
    end
  end

  # A plain linked Task rather than `CodeLead.TaskSupervisor`: the
  # bounded callers are stoppers running under a supervisor shutdown,
  # where the task supervisor may already be terminating.
  defp exec_bounded(path, args, timeout) do
    task = Task.async(fn -> exec(path, args) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timed_out_or_died -> {:error, :timeout}
    end
  end
end
