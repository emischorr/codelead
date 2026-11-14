defmodule FrontSeatWeb.PreviewHostWsTest do
  # async: false — flips the global preview gateway and serves the real
  # endpoint over TCP (shared sandbox).
  use FrontSeatWeb.ConnCase, async: false

  import FrontSeat.PreviewGatewayHelpers
  import FrontSeat.ProjectsFixtures
  import FrontSeat.TasksFixtures

  alias FrontSeatWeb.PreviewHost.Auth

  @domain "preview.localhost"

  # Websocket previews end-to-end through the real endpoint: a Bandit
  # listener serves `FrontSeatWeb.Endpoint`, a second one is the ws-echo
  # upstream, and a Mint.WebSocket client plays the browser — presenting
  # the preview subdomain in its Host header (subdomain gateway) or the
  # `/preview/<id>/…` path (path gateway).

  setup do
    upstream =
      start_supervised!(
        {Bandit, plug: FrontSeat.WsEchoPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0},
        id: :ws_upstream
      )

    {:ok, {_address, upstream_port}} = ThousandIsland.listener_info(upstream)

    endpoint =
      start_supervised!(
        {Bandit, plug: FrontSeatWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0},
        id: :endpoint_server
      )

    {:ok, {_address, endpoint_port}} = ThousandIsland.listener_info(endpoint)

    project = project_fixture()
    repository = repository_fixture(project.id, %{preview_port: upstream_port})
    task = task_fixture(project.id, %{target: :repo, repository_id: repository.id})

    %{task: task, endpoint_port: endpoint_port}
  end

  test "echo frames flow through a subdomain preview; a foreign origin is refused", ctx do
    %{task: task, endpoint_port: endpoint_port, conn: conn} = ctx
    subdomain_gateway!(domain: @domain, url: [scheme: "http", port: endpoint_port])
    host = "task-#{task.id}.#{@domain}"

    # Handshake over ConnTest mints a real signed session cookie the
    # TCP request can present.
    token = Auth.sign(FrontSeatWeb.Endpoint, task.id)
    handshake = get(conn, "http://#{host}/?_preview_auth=#{token}")
    assert redirected_to(handshake) == "/"
    cookie = session_cookie(handshake)

    headers = [
      {"host", host},
      {"cookie", cookie},
      {"origin", "http://#{host}"}
    ]

    assert {:ok, 101, socket} = ws_upgrade(endpoint_port, "/", headers)
    assert ws_roundtrip(socket, "hello through the subdomain") == "hello through the subdomain"

    assert {:ok, 403, _refused} =
             ws_upgrade(
               endpoint_port,
               "/",
               List.keyreplace(headers, "origin", 0, {"origin", "http://evil.example"})
             )
  end

  test "echo frames flow through a path preview", ctx do
    %{task: task, endpoint_port: endpoint_port} = ctx

    headers = [
      {"host", "www.example.com"},
      {"cookie", app_session_cookie()},
      {"origin", "http://www.example.com"}
    ]

    assert {:ok, 101, socket} = ws_upgrade(endpoint_port, "/preview/#{task.id}/ws", headers)
    assert ws_roundtrip(socket, "hello through the path proxy") == "hello through the path proxy"
  end

  ## Cookie minting

  defp session_cookie(conn) do
    conn
    |> Plug.Conn.get_resp_header("set-cookie")
    |> Enum.find(&String.starts_with?(&1, "_fsp_session="))
    |> String.split(";")
    |> hd()
  end

  # A real signed `_front_seat_key` for the path pipeline: the session is
  # written through the endpoint's own Plug.Session so the TCP request
  # authenticates like a browser would.
  defp app_session_cookie do
    user = FrontSeat.AccountsFixtures.admin_fixture()
    token = FrontSeat.Accounts.generate_user_session_token(user)

    Plug.Test.conn(:get, "/")
    |> Map.put(:secret_key_base, FrontSeatWeb.Endpoint.config(:secret_key_base))
    |> Plug.Session.call(Plug.Session.init(FrontSeatWeb.Endpoint.session_options()))
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.send_resp(200, "")
    |> Plug.Conn.get_resp_header("set-cookie")
    |> hd()
    |> String.split(";")
    |> hd()
  end

  ## Minimal Mint.WebSocket client

  defp ws_upgrade(port, path, headers) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, headers)

    {conn, status, resp_headers} = await_upgrade(conn, ref, nil, [])

    if status == 101 do
      {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, resp_headers)
      {:ok, 101, %{conn: conn, ref: ref, websocket: websocket}}
    else
      Mint.HTTP.close(conn)
      {:ok, status, nil}
    end
  end

  defp await_upgrade(conn, ref, status, headers) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status =
              Enum.find_value(responses, status, fn
                {:status, ^ref, new_status} -> new_status
                _other -> nil
              end)

            headers =
              headers ++
                Enum.flat_map(responses, fn
                  {:headers, ^ref, hs} -> hs
                  _other -> []
                end)

            if status != nil and headers != [] do
              {conn, status, headers}
            else
              await_upgrade(conn, ref, status, headers)
            end

          :unknown ->
            await_upgrade(conn, ref, status, headers)
        end
    after
      2_000 -> flunk("websocket upgrade timed out")
    end
  end

  defp ws_roundtrip(%{conn: conn, ref: ref, websocket: websocket} = socket, text) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, text})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

    await_text(%{socket | conn: conn, websocket: websocket})
  end

  defp await_text(%{conn: conn, ref: ref, websocket: websocket} = socket) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            data =
              Enum.find_value(responses, fn
                {:data, ^ref, data} -> data
                _other -> nil
              end)

            case data do
              nil ->
                await_text(%{socket | conn: conn})

              data ->
                {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)

                text =
                  Enum.find_value(frames, fn
                    {:text, text} -> text
                    _other -> nil
                  end)

                case text do
                  nil -> await_text(%{socket | conn: conn, websocket: websocket})
                  text -> text
                end
            end

          :unknown ->
            await_text(socket)
        end
    after
      2_000 -> flunk("websocket echo timed out")
    end
  end
end
