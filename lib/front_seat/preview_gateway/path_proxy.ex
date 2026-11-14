defmodule FrontSeat.PreviewGateway.PathProxy do
  @moduledoc """
  Path-prefix preview gateway: tasks are previewed at
  `/preview/:task_id/` on the app's own origin, reverse-proxied by
  `FrontSeatWeb.PreviewProxyController`. Upstream resolution is the
  shared `FrontSeat.PreviewGateway.Upstream`.
  """

  @behaviour FrontSeat.PreviewGateway

  alias FrontSeat.PreviewGateway
  alias FrontSeat.PreviewGateway.Upstream
  alias FrontSeat.Tasks.Task

  @impl true
  def url_for(%Task{} = task) do
    with {:ok, _port} <- PreviewGateway.preview_port(task) do
      {:ok, "/preview/#{task.id}/"}
    end
  end

  @impl true
  def upstream_for(%Task{} = task), do: Upstream.resolve(task)
end
