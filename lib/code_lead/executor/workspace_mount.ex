defmodule CodeLead.Executor.WorkspaceMount do
  @moduledoc """
  How a sibling container sees the workspace — shared by the task
  devcontainers (`CodeLead.Executor.Devcontainer`) and the one-shot
  harness build (`CodeLead.Executor.HarnessStaging`).
  """

  alias CodeLead.Workspace

  @doc """
  The `-v` docker flags for the workspace, resolved in precedence order:
  named volume (deployed stack), `HOST_DATA_ROOT` bind (escape hatch),
  bind of the workspace root at the identical path (dev, host BEAM).
  All three keep host and container paths coincident — the rule
  everything host-side (git, fs capabilities) depends on.
  """
  @spec flags() :: [String.t()]
  def flags do
    case resolve() do
      {:volume, volume, mount} -> ["-v", "#{volume}:#{mount}"]
      {:bind, source, mount} -> ["-v", "#{source}:#{mount}"]
    end
  end

  @doc """
  The same workspace mount as `flags/0`, in the devcontainer CLI's
  `--mount` spec syntax. Mounted into the task's devcontainer so the
  worktree (and its gitdir in the base clone) and the staged harness
  resolve at their coincident paths.
  """
  @spec devcontainer_mounts() :: [String.t()]
  def devcontainer_mounts do
    case resolve() do
      {:volume, volume, mount} -> ["type=volume,source=#{volume},target=#{mount}"]
      {:bind, source, mount} -> ["type=bind,source=#{source},target=#{mount}"]
    end
  end

  defp resolve do
    volume = Application.get_env(:code_lead, :workspace_volume)
    mount = Application.get_env(:code_lead, :workspace_volume_mount, "/data")
    host_root = Application.get_env(:code_lead, :host_data_root)
    root = Workspace.root()

    cond do
      is_binary(volume) and volume != "" -> {:volume, volume, mount}
      is_binary(host_root) and host_root != "" -> {:bind, host_root, mount}
      true -> {:bind, root, root}
    end
  end
end
