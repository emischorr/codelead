defmodule CodeLead.Workspace.Remover do
  @moduledoc """
  Verified removal of directories inside the managed workspace.

  `File.rm_rf/1` runs as the app's own uid, which cannot delete files a
  container-executed agent wrote as root (the entrypoint chown is
  deliberately non-recursive). When that happens and a docker CLI is
  available, the tree is deleted again as root through a short-lived
  maintenance container — the same privilege the files were created
  with. Installs without docker simply skip the fallback and surface
  the leftover.

  Every call verifies the path is actually gone before reporting `:ok`;
  silent partial removals are the failure mode this module exists to
  kill. As a safety invariant for the root-privileged `rm -rf`, paths
  outside `CodeLead.Workspace.root/0` are refused outright.
  """

  require Logger

  alias CodeLead.Executor.DockerCli
  alias CodeLead.Workspace

  @doc """
  Removes a directory tree under the workspace root, escalating to a
  root-privileged docker removal when plain deletion cannot finish.
  """
  @spec remove_dir(String.t()) :: :ok | {:error, term()}
  def remove_dir(path) do
    cond do
      not Workspace.under_root?(path) ->
        {:error, {:outside_workspace, path}}

      not File.exists?(path) ->
        :ok

      true ->
        _ = File.rm_rf(path)

        if File.exists?(path) do
          remove_as_root(path)
        else
          :ok
        end
    end
  end

  # Leftovers here are almost always root-owned files from a container
  # run, so the fallback re-runs the delete with the same privilege
  # through the docker daemon the executor already talks to.
  defp remove_as_root(path) do
    if DockerCli.available?() do
      Logger.warning("workspace remover: escalating to docker root removal of #{path}")
      parent = Path.dirname(path)
      args = ["run", "--rm", "-v", "#{parent}:#{parent}", maintenance_image(), "rm", "-rf", path]

      case DockerCli.run(args) do
        {:ok, _output} -> verify_removed(path)
        {:error, reason} -> report_leftover(path, {:leftover_root_files, path}, reason)
      end
    else
      {:error, {:leftover, path}}
    end
  end

  defp verify_removed(path) do
    if File.exists?(path) do
      report_leftover(path, {:leftover_root_files, path}, :still_present)
    else
      :ok
    end
  end

  defp report_leftover(path, error, detail) do
    Logger.error(
      "workspace remover: could not remove #{path} even as root (#{inspect(detail)}) — " <>
        "remove it manually on the host"
    )

    {:error, error}
  end

  defp maintenance_image do
    Application.get_env(:code_lead, :maintenance_image, "alpine:3.20")
  end
end
