defmodule CodeLead.Executor.WorkspaceMountTest do
  # async: false — swaps the process-global mount-mode configs.
  use ExUnit.Case, async: false

  alias CodeLead.Executor.WorkspaceMount
  alias CodeLead.Workspace

  setup do
    keys = [:workspace_volume, :workspace_volume_mount, :host_data_root]
    originals = Enum.map(keys, &{&1, Application.get_env(:code_lead, &1)})

    Application.put_env(:code_lead, :workspace_volume, nil)
    # runtime.exs always stores this one; nil would defeat the default.
    Application.put_env(:code_lead, :workspace_volume_mount, "/data")
    Application.put_env(:code_lead, :host_data_root, nil)

    on_exit(fn ->
      Enum.each(originals, fn {key, value} -> Application.put_env(:code_lead, key, value) end)
    end)

    :ok
  end

  test "default mode binds the workspace root at the identical path and is coincident" do
    root = Workspace.root()

    assert WorkspaceMount.flags() == ["-v", "#{root}:#{root}"]
    assert WorkspaceMount.devcontainer_mounts() == ["type=bind,source=#{root},target=#{root}"]
    assert WorkspaceMount.coincident?()
  end

  test "legacy named-volume mode is not coincident" do
    Application.put_env(:code_lead, :workspace_volume, "codelead-data")

    assert WorkspaceMount.devcontainer_mounts() ==
             ["type=volume,source=codelead-data,target=/data"]

    refute WorkspaceMount.coincident?()
  end

  test "legacy HOST_DATA_ROOT mode is not coincident unless both sides match" do
    Application.put_env(:code_lead, :host_data_root, "/srv/codelead/data")
    refute WorkspaceMount.coincident?()

    # An operator who mounts the host path at the identical container
    # path satisfies the rule even through the legacy variable.
    Application.put_env(:code_lead, :workspace_volume_mount, "/srv/codelead/data")
    assert WorkspaceMount.coincident?()
  end
end
