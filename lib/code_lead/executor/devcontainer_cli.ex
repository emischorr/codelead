defmodule CodeLead.Executor.DevcontainerCli do
  @moduledoc """
  Thin transport to the devcontainer CLI (`@devcontainers/cli`). The
  argv head comes from the `:devcontainer_cli` config key so tests can
  swap in a fake, mirroring the `:docker_cli` pattern.

  `up/2` runs `devcontainer up` as a Port. With `--log-format json` the
  result object is the single stdout line while progress events stream
  on stderr; both are merged here, progress is logged, a bounded tail is
  kept for error detail, and the result is parsed off the one line
  carrying an `"outcome"` key.
  """

  require Logger

  @type up_result :: %{
          container_id: String.t(),
          compose_project: String.t() | nil,
          remote_user: String.t() | nil,
          remote_workspace_folder: String.t() | nil
        }

  # The first `up` for a repo may pull/build images and install
  # devcontainer features.
  @default_up_timeout_ms 30 * 60_000
  @tail_bytes 4_096

  @doc """
  The resolved CLI executable and the remaining argv prefix, or an error
  when the configured head is not on the server's PATH.
  """
  @spec cli() :: {:ok, {String.t(), [String.t()]}} | {:error, :devcontainer_cli_not_found}
  def cli do
    [head | prefix] = Application.get_env(:code_lead, :devcontainer_cli, ["devcontainer"])

    case System.find_executable(head) do
      nil -> {:error, :devcontainer_cli_not_found}
      resolved -> {:ok, {resolved, prefix}}
    end
  end

  @spec available?() :: boolean()
  def available?, do: match?({:ok, _resolved}, cli())

  @doc """
  Runs `devcontainer up` for the workspace folder and returns the
  resolved primary container. Idempotent: an existing matching
  environment is reused, a stopped one restarted.

  Options: `:id_labels` (`[{key, value}]`, the container identity),
  `:mounts` (extra `--mount` specs), `:config` (explicit path to a
  devcontainer.json, `nil` for spec-order auto-discovery).
  """
  @spec up(String.t(), keyword()) ::
          {:ok, up_result()}
          | {:error,
             {:devcontainer_up_failed, String.t(), String.t()} | :devcontainer_cli_not_found}
  def up(workspace_folder, opts \\ []) do
    with {:ok, {path, prefix}} <- cli() do
      args =
        prefix ++
          ["up", "--workspace-folder", workspace_folder, "--log-format", "json"] ++
          Enum.flat_map(Keyword.get(opts, :id_labels, []), fn {key, value} ->
            ["--id-label", "#{key}=#{value}"]
          end) ++
          Enum.flat_map(Keyword.get(opts, :mounts, []), &["--mount", &1]) ++
          config_args(Keyword.get(opts, :config))

      port =
        Port.open(
          {:spawn_executable, path},
          [:binary, :exit_status, :hide, :stderr_to_stdout, args: args]
        )

      collect(port, "", nil, "")
    end
  end

  defp config_args(nil), do: []
  defp config_args(config_path), do: ["--config", config_path]

  # Accumulates port output line-wise: `partial` is the unterminated
  # last line, `result` the decoded object carrying "outcome" (progress
  # events carry "type" instead), `tail` a bounded transcript for error
  # detail.
  defp collect(port, partial, result, tail) do
    timeout = Application.get_env(:code_lead, :devcontainer_up_timeout_ms, @default_up_timeout_ms)

    receive do
      {^port, {:data, data}} ->
        {lines, partial} = split_lines(partial <> data)
        result = Enum.reduce(lines, result, &scan_line/2)
        collect(port, partial, result, trim_tail(tail <> data))

      {^port, {:exit_status, status}} ->
        finish(status, scan_line(partial, result), tail)
    after
      timeout ->
        _ = safe_close(port)
        {:error, {:devcontainer_up_failed, "devcontainer up timed out", trim_tail(tail)}}
    end
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n") do
      [partial] -> {[], partial}
      lines -> {Enum.drop(lines, -1), List.last(lines)}
    end
  end

  defp scan_line(line, result) do
    case Jason.decode(line) do
      {:ok, %{"outcome" => _outcome} = decoded} ->
        decoded

      {:ok, %{"text" => text}} when is_binary(text) and text != "" ->
        Logger.debug("devcontainer up: #{String.trim_trailing(text)}")
        result

      _progress_or_noise ->
        result
    end
  end

  defp finish(0, %{"outcome" => "success", "containerId" => container_id} = result, _tail)
       when is_binary(container_id) and container_id != "" do
    {:ok,
     %{
       container_id: container_id,
       compose_project: blank_to_nil(result["composeProjectName"]),
       remote_user: blank_to_nil(result["remoteUser"]),
       remote_workspace_folder: blank_to_nil(result["remoteWorkspaceFolder"])
     }}
  end

  defp finish(_status, %{"outcome" => "error"} = result, tail) do
    message = result["message"] || result["description"] || "devcontainer up failed"
    {:error, {:devcontainer_up_failed, message, trim_tail(tail)}}
  end

  defp finish(0, _no_result, tail) do
    {:error, {:devcontainer_up_failed, "devcontainer up reported no result", trim_tail(tail)}}
  end

  defp finish(status, _no_result, tail) do
    {:error,
     {:devcontainer_up_failed, "devcontainer up exited with status #{status}", trim_tail(tail)}}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp trim_tail(tail) when byte_size(tail) > @tail_bytes do
    binary_part(tail, byte_size(tail) - @tail_bytes, @tail_bytes)
  end

  defp trim_tail(tail), do: tail

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
