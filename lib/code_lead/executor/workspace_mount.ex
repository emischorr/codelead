defmodule CodeLead.Executor.WorkspaceMount do
  @moduledoc """
  How a sibling container sees the workspace — shared by the task
  containers (`CodeLead.Executor.DockerContainer`) and the one-shot
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
    volume = Application.get_env(:code_lead, :workspace_volume)
    mount = Application.get_env(:code_lead, :workspace_volume_mount, "/data")
    host_root = Application.get_env(:code_lead, :host_data_root)
    root = Workspace.root()

    cond do
      is_binary(volume) and volume != "" -> ["-v", "#{volume}:#{mount}"]
      is_binary(host_root) and host_root != "" -> ["-v", "#{host_root}:#{mount}"]
      true -> ["-v", "#{root}:#{root}"]
    end
  end
end
