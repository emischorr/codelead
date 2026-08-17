defmodule CodeLead.PreviewGateway.PathProxy do
  @moduledoc """
  Path-prefix preview gateway: tasks are previewed at
  `/preview/:task_id/` on the app's own origin, reverse-proxied by
  `CodeLeadWeb.PreviewProxyController`.

  Upstream resolution by execution env:

    * `:local` — the dev server runs in the worktree on this node, so
      the upstream is `127.0.0.1:<preview_port>` (in a deployed stack
      "this node" is the app container, which is still correct).
    * `:container` — a relay sidecar (`CodeLead.PreviewGateway.Relay`)
      joins the task container's network and publishes `preview_port`
      to an ephemeral host port; we dial `:preview_upstream_host`
      (loopback in dev, the docker bridge gateway in a deployed stack)
      at that port.
  """

  @behaviour CodeLead.PreviewGateway

  alias CodeLead.Executor.Devcontainer
  alias CodeLead.PreviewGateway
  alias CodeLead.PreviewGateway.Relay
  alias CodeLead.Tasks.Task

  @impl true
  def url_for(%Task{} = task) do
    with {:ok, _port} <- preview_port(task) do
      {:ok, "/preview/#{task.id}/"}
    end
  end

  @impl true
  def upstream_for(%Task{execution_env: :local} = task) do
    with {:ok, port} <- preview_port(task) do
      {:ok, %{host: "127.0.0.1", port: port}}
    end
  end

  def upstream_for(%Task{execution_env: :container} = task) do
    with {:ok, port} <- preview_port(task),
         {:ok, container_id} <- Devcontainer.container_for_task(task.id),
         {:ok, host_port} <- Relay.ensure(task.id, container_id, port) do
      {:ok, %{host: upstream_host(), port: host_port}}
    else
      {:error, :no_preview_port} = error -> error
      {:error, :unsupported} = error -> error
      # Whatever went wrong (environment gone or stopped, daemon down,
      # relay image unpullable), the honest answer to the proxy is the
      # same branded "not running" page.
      _stopped_absent_or_error -> {:error, :not_running}
    end
  end

  defp preview_port(%Task{} = task), do: PreviewGateway.preview_port(task)

  defp upstream_host do
    Application.get_env(:code_lead, :preview_upstream_host, "127.0.0.1")
  end
end
