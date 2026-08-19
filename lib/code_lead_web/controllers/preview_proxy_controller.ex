defmodule CodeLeadWeb.PreviewProxyController do
  @moduledoc """
  Reverse proxy for task previews under the path gateway:
  `/preview/:task_id/*path` forwards to whatever HTTP server the task's
  execution context runs on its repository's declared `preview_port`
  (see `CodeLead.PreviewGateway`). The forwarding core lives in
  `CodeLeadWeb.PreviewProxy.Forwarder`, shared with the subdomain
  preview host.

  Sits behind its own `:preview` pipeline — session auth without the
  browser conveniences (`accepts`, CSRF, secure headers) that would
  mangle proxied traffic. Like the LiveViews beside it, there is no
  per-task authorization — any logged-in user may view any preview.
  """

  use CodeLeadWeb, :controller

  alias CodeLead.PreviewGateway
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLeadWeb.PreviewProxy.ErrorPages
  alias CodeLeadWeb.PreviewProxy.Forwarder
  alias CodeLeadWeb.PreviewProxy.Policy

  def proxy(conn, %{"task_id" => task_id, "path" => path}) do
    # Under the subdomain gateway these path routes are dead — a stale
    # bookmark must fail loudly and comprehensibly, not half-work.
    if PreviewGateway.impl() == CodeLead.PreviewGateway.SubdomainProxy do
      Forwarder.error_page(conn, 404, ErrorPages.wrong_gateway(task_id))
    else
      proxy_via_path(conn, task_id, path)
    end
  end

  defp proxy_via_path(conn, task_id, path) do
    with %Task{} = task <- lookup_task(task_id),
         {:ok, _url} <- PreviewGateway.impl().url_for(task) do
      dispatch(conn, task, path)
    else
      nil -> Forwarder.error_page(conn, 404, ErrorPages.not_found())
      {:error, :no_preview_port} -> Forwarder.error_page(conn, 404, ErrorPages.no_port())
      {:error, :unsupported} -> Forwarder.error_page(conn, 404, ErrorPages.not_found())
    end
  end

  # Relative URLs inside the previewed app resolve against the current
  # path, so the page must live under `/preview/<id>/` — with a slash.
  defp dispatch(%Plug.Conn{request_path: request_path} = conn, task, [] = _path) do
    if String.ends_with?(request_path, "/") do
      Forwarder.forward(conn, task, Policy.for_task(task.id))
    else
      redirect(conn, to: request_path <> "/")
    end
  end

  defp dispatch(conn, task, _path) do
    Forwarder.forward(conn, task, Policy.for_task(task.id))
  end

  defp lookup_task(task_id) do
    case Integer.parse(task_id) do
      {id, ""} -> Tasks.get_task(id)
      _not_an_id -> nil
    end
  end
end
