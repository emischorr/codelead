defmodule CodeLeadWeb.PreviewProxy.Forwarder do
  @moduledoc """
  The gateway-agnostic forwarding core of the preview proxy: resolves
  the task's upstream, then hands the request to the HTTP half or
  upgrades it onto the websocket relay. Shared by the path-mounted
  `CodeLeadWeb.PreviewProxyController` and the subdomain preview host;
  what differs between them arrives as a `CodeLeadWeb.PreviewProxy.Policy`.
  """

  import Plug.Conn

  alias CodeLead.PreviewGateway
  alias CodeLeadWeb.PreviewProxy.ErrorPages
  alias CodeLeadWeb.PreviewProxy.Headers
  alias CodeLeadWeb.PreviewProxy.HTTP
  alias CodeLeadWeb.PreviewProxy.Policy
  alias CodeLeadWeb.PreviewProxy.WebSocketRelay

  @doc """
  Forwards `conn` to the task's preview upstream under `policy`.
  """
  @spec forward(Plug.Conn.t(), CodeLead.Tasks.Task.t(), Policy.t()) :: Plug.Conn.t()
  def forward(conn, task, %Policy{} = policy) do
    case PreviewGateway.impl().upstream_for(task) do
      {:ok, upstream} ->
        if websocket_upgrade?(conn) do
          upgrade_websocket(conn, upstream, policy)
        else
          HTTP.forward(conn, upstream, policy, upstream_path(conn, policy.mount_path))
        end

      {:error, _not_running} ->
        error_page(conn, 502, ErrorPages.not_running(nil))
    end
  end

  @doc "Sends a branded error page and halts nothing — callers decide."
  @spec error_page(Plug.Conn.t(), pos_integer(), iodata()) :: Plug.Conn.t()
  def error_page(conn, status, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end

  defp upgrade_websocket(conn, upstream, policy) do
    if origin_allowed?(conn) do
      conn
      |> echo_subprotocol()
      |> WebSockAdapter.upgrade(
        WebSocketRelay,
        %{
          upstream: upstream,
          path: upstream_path(conn, policy.mount_path),
          headers: Headers.ws_request_headers(conn, upstream, policy)
        },
        timeout: 120_000,
        compress: false
      )
    else
      send_resp(conn, 403, "forbidden origin")
    end
  end

  defp websocket_upgrade?(conn) do
    upgrade? =
      conn
      |> get_req_header("upgrade")
      |> Enum.any?(&(String.downcase(&1) == "websocket"))

    connection? =
      conn
      |> get_req_header("connection")
      |> Enum.any?(&(&1 |> String.downcase() |> String.contains?("upgrade")))

    upgrade? and connection?
  end

  # Phoenix's `check_origin` does not cover proxied traffic; a cheap
  # same-host check keeps other sites' scripts from opening sockets
  # through the proxy. It holds under both gateways — a preview page on
  # a task subdomain opens its sockets against that same subdomain.
  # Non-browser clients send no origin — allowed.
  defp origin_allowed?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin | _rest] -> URI.parse(origin).host == conn.host
    end
  end

  # Echo the client's first offered subprotocol into the 101 (Bandit
  # includes `resp_headers` in the handshake) — Vite's `vite-hmr`
  # client aborts without the echo.
  defp echo_subprotocol(conn) do
    case get_req_header(conn, "sec-websocket-protocol") do
      [] ->
        conn

      [offer | _rest] ->
        first = offer |> String.split(",") |> hd() |> String.trim()
        put_resp_header(conn, "sec-websocket-protocol", first)
    end
  end

  # Derived from `request_path`, not `path_info`, to preserve the
  # original percent-encoding on the way upstream. An empty mount prefix
  # (subdomain gateway) leaves the path untouched.
  defp upstream_path(conn, prefix) do
    path =
      case String.replace_prefix(conn.request_path, prefix, "") do
        "" -> "/"
        stripped -> stripped
      end

    case conn.query_string do
      "" -> path
      query -> path <> "?" <> query
    end
  end
end
