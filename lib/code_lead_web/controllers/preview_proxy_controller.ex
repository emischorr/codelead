defmodule CodeLeadWeb.PreviewProxyController do
  @moduledoc """
  Reverse proxy for task previews: `/preview/:task_id/*path` forwards
  to whatever HTTP server the task's execution context runs on its
  repository's declared `preview_port` (see `CodeLead.PreviewGateway`).

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
  alias CodeLeadWeb.PreviewProxy.Headers
  alias CodeLeadWeb.PreviewProxy.HTTP
  alias CodeLeadWeb.PreviewProxy.WebSocketRelay

  def proxy(conn, %{"task_id" => task_id, "path" => path}) do
    with %Task{} = task <- lookup_task(task_id),
         {:ok, _url} <- PreviewGateway.impl().url_for(task) do
      dispatch(conn, task, path)
    else
      nil -> error_page(conn, 404, ErrorPages.not_found())
      {:error, :no_preview_port} -> error_page(conn, 404, ErrorPages.no_port())
      {:error, :unsupported} -> error_page(conn, 404, ErrorPages.not_found())
    end
  end

  # Relative URLs inside the previewed app resolve against the current
  # path, so the frame must live under `/preview/<id>/` — with a slash.
  defp dispatch(%Plug.Conn{request_path: request_path} = conn, task, [] = _path) do
    if String.ends_with?(request_path, "/") do
      forward_upstream(conn, task)
    else
      redirect(conn, to: request_path <> "/")
    end
  end

  defp dispatch(conn, task, _path), do: forward_upstream(conn, task)

  defp forward_upstream(conn, task) do
    prefix = "/preview/#{task.id}"

    case PreviewGateway.impl().upstream_for(task) do
      {:ok, upstream} ->
        if websocket_upgrade?(conn) do
          upgrade_websocket(conn, upstream, prefix)
        else
          HTTP.forward(conn, upstream, prefix, upstream_path(conn, prefix))
        end

      {:error, _not_running} ->
        error_page(conn, 502, ErrorPages.not_running(nil))
    end
  end

  defp upgrade_websocket(conn, upstream, prefix) do
    if origin_allowed?(conn) do
      conn
      |> echo_subprotocol()
      |> WebSockAdapter.upgrade(
        WebSocketRelay,
        %{
          upstream: upstream,
          path: upstream_path(conn, prefix),
          headers: Headers.ws_request_headers(conn, upstream, prefix)
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

  # Phoenix's `check_origin` does not cover this route; a cheap
  # same-host check keeps other sites' scripts from opening sockets
  # through the proxy. Non-browser clients send no origin — allowed.
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
  # original percent-encoding on the way upstream.
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

  defp lookup_task(task_id) do
    case Integer.parse(task_id) do
      {id, ""} -> Tasks.get_task(id)
      _not_an_id -> nil
    end
  end

  defp error_page(conn, status, html) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
  end
end
