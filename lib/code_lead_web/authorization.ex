defmodule CodeLeadWeb.Authorization do
  @moduledoc """
  The third browser gate, after `CodeLeadWeb.SetupGate` and
  `CodeLeadWeb.UserAuth`: authorization. Like the other two it has two
  faces per requirement — a plug for HTTP requests (and controller
  routes) and an `on_mount` hook for live navigation inside a
  `live_session`, which never re-runs router pipelines.

  `require_admin` guards the instance-administration pages; non-admins
  bounce to `/settings` with a flash.

  `require_project_access` guards every project-keyed route. A caller
  without `:view_project` gets a generic "Project not found" redirect to
  `/` — never a 403, so project ids don't enumerate. It reads
  `params["project_id"] || params["id"]`; the `|| params["id"]` fallback
  (for `/settings/projects/:id`) is safe **only** while the `:project`
  live_session and the routes using the plug carry exclusively
  project-keyed ids. A route whose `:id` names anything else must not
  join them.
  """

  use CodeLeadWeb, :verified_routes

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]
  import Plug.Conn, only: [halt: 1]

  alias CodeLead.Accounts.Policy
  alias CodeLead.Accounts.Scope

  @not_found "Project not found"

  ## Plug faces

  @spec require_admin(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_admin(conn, _opts) do
    if Scope.admin?(conn.assigns[:current_scope]) do
      conn
    else
      conn
      |> Phoenix.Controller.put_flash(:error, "Administrator access required.")
      |> Phoenix.Controller.redirect(to: ~p"/settings")
      |> halt()
    end
  end

  @spec require_project_access(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_project_access(conn, _opts) do
    case check_project_access(conn.assigns[:current_scope], conn.path_params) do
      :ok ->
        conn

      :error ->
        conn
        |> Phoenix.Controller.put_flash(:error, @not_found)
        |> Phoenix.Controller.redirect(to: ~p"/")
        |> halt()
    end
  end

  ## on_mount faces

  def on_mount(:require_admin, _params, _session, socket) do
    if Scope.admin?(socket.assigns[:current_scope]) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, "Administrator access required.")
       |> redirect(to: ~p"/settings")}
    end
  end

  def on_mount(:require_project_access, params, _session, socket) do
    case check_project_access(socket.assigns[:current_scope], params) do
      :ok -> {:cont, socket}
      :error -> {:halt, socket |> put_flash(:error, @not_found) |> redirect(to: ~p"/")}
    end
  end

  # A non-member and a nonexistent id take the same refusal path, so the
  # redirect reveals nothing. Admins pass on any id; the page's own
  # `get_project!/1` turns a made-up one into a 404 for them.
  defp check_project_access(scope, params) do
    with raw when is_binary(raw) <- params["project_id"] || params["id"] || :error,
         {id, ""} <- Integer.parse(raw),
         true <- Policy.can?(scope, :view_project, id) do
      :ok
    else
      _refused -> :error
    end
  end
end
