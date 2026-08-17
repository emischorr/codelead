defmodule CodeLead.Executor.WorkspaceMount do
  @moduledoc """
  How a sibling container sees the workspace — shared by the task
  devcontainers (`CodeLead.Executor.Devcontainer`) and the one-shot
  harness build (`CodeLead.Executor.HarnessStaging`).

  Devcontainer execution (ADR-0009) additionally requires the workspace
  root to be *host-coincident*: the devcontainer CLI resolves the
  repository's own bind sources (its compose file, the CLI's workspace
  mount) against this process's filesystem view and hands them to the
  host daemon, so both must see the workspace at the identical path.
  The legacy `WORKSPACE_VOLUME`/`HOST_DATA_ROOT` modes cannot satisfy
  that — they remain resolvable here exactly so container tasks can
  refuse with guidance (`coincident?/0`) instead of building against
  an empty phantom directory the daemon auto-creates.
  """

  alias CodeLead.Workspace

  @doc """
  The `-v` docker flags for the workspace, resolved in precedence order:
  named volume (`WORKSPACE_VOLUME`, legacy), `HOST_DATA_ROOT` bind
  (legacy), bind of the workspace root at the identical path (the rule
  everything depends on — see `coincident?/0`).
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

  @doc """
  Whether the workspace root is host-coincident — the topology
  devcontainer execution requires (see the moduledoc).
  """
  @spec coincident?() :: boolean()
  def coincident? do
    match?({:bind, path, path}, resolve())
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
