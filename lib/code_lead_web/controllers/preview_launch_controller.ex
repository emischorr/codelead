defmodule CodeLeadWeb.PreviewLaunchController do
  @moduledoc """
  The Open-preview target: turns a task into the active gateway's
  preview URL and redirects the fresh browser tab there. This is the
  only web surface that produces a browser-facing preview URL — the
  LiveViews link here and never build one themselves.

  Under the path gateway the redirect is a plain relative hop onto
  `/preview/<id>/`. Under the subdomain gateway `url_for/1` is an
  absolute URL on a foreign origin that has no session, so the redirect
  carries a short-lived task-scoped token the preview host exchanges
  for its own session cookie (see `CodeLeadWeb.PreviewHost.Auth`).
  Minting at click time keeps the token out of rendered HTML and makes
  its 60-second lifetime start when the user actually clicks.
  """

  use CodeLeadWeb, :controller

  alias CodeLead.PreviewGateway
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLeadWeb.PreviewHost.Auth
  alias CodeLeadWeb.PreviewProxy.ErrorPages
  alias CodeLeadWeb.PreviewProxy.Forwarder

  def launch(conn, %{"task_id" => task_id}) do
    with %Task{} = task <- lookup_task(task_id),
         {:ok, url} <- PreviewGateway.impl().url_for(task) do
      case URI.parse(url) do
        %URI{host: nil} ->
          redirect(conn, to: url)

        %URI{} ->
          token = Auth.sign(conn, task.id)
          redirect(conn, external: url <> "?" <> Auth.token_param() <> "=" <> token)
      end
    else
      nil -> Forwarder.error_page(conn, 404, ErrorPages.not_found())
      {:error, :no_preview_port} -> Forwarder.error_page(conn, 404, ErrorPages.no_port())
      {:error, :unsupported} -> Forwarder.error_page(conn, 404, ErrorPages.not_found())
    end
  end

  defp lookup_task(task_id) do
    case Integer.parse(task_id) do
      {id, ""} -> Tasks.get_task(id)
      _not_an_id -> nil
    end
  end
end
