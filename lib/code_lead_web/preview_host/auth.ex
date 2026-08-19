defmodule CodeLeadWeb.PreviewHost.Auth do
  @moduledoc """
  Auth gate for preview subdomains. The app's session cookie is
  host-only, so a preview origin starts with no session at all; the
  Open-preview link (`CodeLeadWeb.PreviewLaunchController`) carries a
  short-lived task-scoped `Phoenix.Token` instead. First visit: verify
  the token, seed this host's own session with the task id, and
  redirect to `/` so the token leaves the URL and the browser history.
  Every later request rides the session cookie.

  The token proves "came from a logged-in CodeLead session" — nothing
  finer-grained, matching the path gateway (any logged-in user may view
  any preview). A visit with no token and no session gets a branded 401
  telling the user to open the preview from CodeLead.
  """

  import Plug.Conn

  alias CodeLeadWeb.PreviewProxy.ErrorPages
  alias CodeLeadWeb.PreviewProxy.Forwarder

  @token_param "_preview_auth"
  @token_salt "preview host"
  @token_max_age 60

  @doc "Passes an authenticated conn through; halts otherwise."
  @spec call(Plug.Conn.t(), integer()) :: Plug.Conn.t()
  def call(conn, task_id) do
    if get_session(conn, :preview_task_id) == task_id do
      conn
    else
      conn = fetch_query_params(conn)

      case conn.query_params[@token_param] do
        nil -> refuse(conn)
        token -> verify(conn, token, task_id)
      end
    end
  end

  @doc "Signs the launch token for a task. The clock starts at signing."
  @spec sign(Plug.Conn.t() | module(), integer()) :: String.t()
  def sign(conn_or_endpoint, task_id) do
    Phoenix.Token.sign(conn_or_endpoint, @token_salt, %{task_id: task_id})
  end

  @doc "The query parameter the launch redirect carries the token in."
  @spec token_param() :: String.t()
  def token_param, do: @token_param

  defp verify(conn, token, task_id) do
    case Phoenix.Token.verify(conn, @token_salt, token, max_age: @token_max_age) do
      {:ok, %{task_id: ^task_id}} ->
        conn
        |> put_session(:preview_task_id, task_id)
        |> configure_session(renew: true)
        |> Phoenix.Controller.redirect(to: "/")
        |> halt()

      # Expired, tampered, or minted for another task's host — the fix
      # is the same: go back to CodeLead and click Open preview again.
      _invalid_expired_or_wrong_task ->
        refuse(conn)
    end
  end

  defp refuse(conn) do
    conn
    |> Forwarder.error_page(401, ErrorPages.handshake_required())
    |> halt()
  end
end
