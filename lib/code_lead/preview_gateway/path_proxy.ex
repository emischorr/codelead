defmodule CodeLead.PreviewGateway.PathProxy do
  @moduledoc """
  Path-prefix preview gateway: tasks are previewed at
  `/preview/:task_id/` on the app's own origin, reverse-proxied by
  `CodeLeadWeb.PreviewProxyController`. Upstream resolution is the
  shared `CodeLead.PreviewGateway.Upstream`.
  """

  @behaviour CodeLead.PreviewGateway

  alias CodeLead.PreviewGateway
  alias CodeLead.PreviewGateway.Upstream
  alias CodeLead.Tasks.Task

  @impl true
  def url_for(%Task{} = task) do
    with {:ok, _port} <- PreviewGateway.preview_port(task) do
      {:ok, "/preview/#{task.id}/"}
    end
  end

  @impl true
  def upstream_for(%Task{} = task), do: Upstream.resolve(task)
end
