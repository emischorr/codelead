defmodule CodeLeadWeb.Plugs.RequirePreviewAccess do
  @moduledoc """
  Auth gate for the preview proxy: same session, same requirements as
  the app routes (instance set up + user logged in), but failure is a
  minimal 401 page instead of a login redirect — these requests come
  from an iframe or asset context where a redirect renders garbage.
  The page hosting the iframe sits behind the full auth stack, so a
  401 here only ever means an expired session.
  """

  @behaviour Plug

  import Plug.Conn

  alias CodeLead.Accounts
  alias CodeLeadWeb.PreviewProxy.ErrorPages

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_scope: scope}} = conn, _opts) do
    if Accounts.setup_done?() and scope != nil and scope.user != nil do
      conn
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(401, ErrorPages.unauthorized())
      |> halt()
    end
  end
end
