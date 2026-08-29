defmodule CodeLeadWeb.Plugs.RequirePreviewAccess do
  @moduledoc """
  Auth gate for the path-gateway preview proxy: same session, same
  requirements as the app routes (instance set up + user logged in),
  but failure is a minimal 401 page instead of a login redirect — most
  of these requests are the previewed app's own asset and XHR fetches,
  where a redirect renders garbage. Subdomain-gateway traffic never
  passes through here (it is diverted by host before the router); its
  gate is `CodeLeadWeb.PreviewHost.Auth`.
  """

  @behaviour Plug

  import Plug.Conn

  alias CodeLead.Accounts
  alias CodeLead.Accounts.Policy
  alias CodeLead.Tasks
  alias CodeLeadWeb.PreviewProxy.ErrorPages

  # Mirrors `CodeLeadWeb.Endpoint`'s `@session_options[:key]` and
  # `CodeLeadWeb.UserAuth`'s `@remember_me_cookie`.
  @host_cookies ~w(_code_lead_key _code_lead_web_user_remember_me)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_scope: scope}} = conn, _opts) do
    if Accounts.setup_done?() and scope != nil and scope.user != nil and
         project_allowed?(scope, conn.path_info) do
      conn
    else
      {conn, shadowed?} = evict_shadow_cookies(conn)

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(401, ErrorPages.unauthorized(shadowed?))
      |> halt()
    end
  end

  # A preview proxies into the task's execution context, so it needs
  # `:view_project` on the task's project — the same rule as the task
  # page. An unknown or unparseable task id passes through: the
  # controllers own the branded 404 for those.
  defp project_allowed?(scope, path_info) do
    with raw when is_binary(raw) <- preview_task_id(path_info),
         {task_id, ""} <- Integer.parse(raw),
         project_id when is_integer(project_id) <- Tasks.task_project_id(task_id) do
      Policy.can?(scope, :view_project, project_id)
    else
      _unresolved -> true
    end
  end

  defp preview_task_id(["preview", "launch", raw | _rest]), do: raw
  defp preview_task_id(["preview", raw | _rest]), do: raw
  defp preview_task_id(_path_info), do: nil

  # An earlier build let a previewed CodeLead plant its own
  # `_code_lead_key` on this origin under the preview path. Browsers send
  # the longer-path cookie first and Plug resolves a duplicate name to
  # the leftmost pair, so that shadow wins over the real session and this
  # gate 401s for good — and it runs before the proxy, so the proxy can
  # never emit the eviction itself. Every proxied cookie is namespaced
  # now, so nothing legitimate lives under the mount: denying is the
  # moment to clear them. Only a name that arrived *twice* proves a
  # shadow, and only that case earns the self-healing reload — a plain
  # expired session must not sit in a refresh loop.
  defp evict_shadow_cookies(%Plug.Conn{path_info: ["preview", task_id | _rest]} = conn) do
    names = cookie_names(conn)
    present = Enum.filter(@host_cookies, &(&1 in names))
    shadowed? = Enum.any?(present, &(Enum.count(names, fn name -> name == &1 end) > 1))

    conn =
      Enum.reduce(present, conn, &delete_resp_cookie(&2, &1, path: "/preview/#{task_id}"))

    {conn, shadowed?}
  end

  defp evict_shadow_cookies(conn), do: {conn, false}

  # The raw header, not `conn.cookies` — the duplicate is the signal and
  # Plug's parsed map has already collapsed it.
  defp cookie_names(conn) do
    conn
    |> get_req_header("cookie")
    |> Enum.flat_map(&String.split(&1, ";"))
    |> Enum.map(&(&1 |> String.trim() |> String.split("=", parts: 2) |> hd()))
  end
end
