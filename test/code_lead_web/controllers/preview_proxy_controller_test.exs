defmodule CodeLeadWeb.PreviewProxyControllerTest do
  use CodeLeadWeb.ConnCase, async: true

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  # Boots a real Bandit upstream on an ephemeral loopback port and
  # points the task's repository at it — the proxy then resolves it
  # through the real `PathProxy` local branch, no stubbing needed.
  defp task_with_upstream(_context) do
    upstream =
      start_supervised!(
        {Bandit, plug: CodeLead.PreviewUpstreamPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(upstream)

    %{task: repo_task(port), port: port}
  end

  defp repo_task(preview_port) do
    project = project_fixture()
    repository = repository_fixture(project.id, %{preview_port: preview_port})

    task_fixture(project.id, %{target: :repo, repository_id: repository.id})
  end

  # A port that was just free — nothing listens on it.
  defp dead_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  describe "unauthenticated" do
    test "responds 401 with the branded page, not a redirect", %{conn: conn} do
      # Any declared port works — 4000 itself is refused these days (the
      # instance's own port).
      task = repo_task(4321)

      conn = get(conn, "/preview/#{task.id}/")

      assert conn.status == 401
      assert conn.resp_body =~ "Session expired"
    end
  end

  describe "authenticated, upstream running" do
    setup [:register_and_log_in_user, :task_with_upstream]

    test "forwards method, path, and query", %{conn: conn, task: task} do
      conn = get(conn, "/preview/#{task.id}/info?a=1&b=2")

      assert conn.status == 200
      assert conn.resp_body =~ "GET /info?a=1&b=2"
    end

    test "stamps x-forwarded-* and strips hop-by-hop request headers", %{conn: conn, task: task} do
      conn =
        conn
        |> put_req_header("connection", "keep-alive")
        |> get("/preview/#{task.id}/info")

      assert conn.resp_body =~ "x-forwarded-prefix: /preview/#{task.id}"
      assert conn.resp_body =~ "x-forwarded-proto: http"
      refute conn.resp_body =~ "connection: keep-alive"
    end

    test "keeps the app session cookie out of the upstream", %{conn: conn, task: task} do
      conn =
        conn
        |> put_req_header("cookie", "_code_lead_key=secret; devtool=1")
        |> get("/preview/#{task.id}/info")

      assert conn.resp_body =~ "cookie: devtool=1"
      refute conn.resp_body =~ "_code_lead_key"
    end

    test "forwards a POST body byte-for-byte despite Plug.Parsers", %{conn: conn, task: task} do
      raw = ~s({"a": [1, 2], "keep": "as-is"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/preview/#{task.id}/echo", raw)

      assert conn.status == 200
      assert conn.resp_body == raw
    end

    test "streams chunked responses through", %{conn: conn, task: task} do
      conn = get(conn, "/preview/#{task.id}/sse")

      assert conn.status == 200
      assert conn.resp_body == "chunk1chunk2"
    end

    test "rewrites root-relative redirects onto the prefix", %{conn: conn, task: task} do
      conn = get(conn, "/preview/#{task.id}/redirect")

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/preview/#{task.id}/after"]
    end

    test "passes bodiless statuses through unchunked", %{conn: conn, task: task} do
      conn = get(conn, "/preview/#{task.id}/nocontent")

      assert conn.status == 204
    end

    test "strips hop-by-hop response headers, keeps the rest", %{conn: conn, task: task} do
      conn = get(conn, "/preview/#{task.id}/hop")

      assert get_resp_header(conn, "x-upstream") == ["yes"]
      assert get_resp_header(conn, "keep-alive") == []
    end

    test "redirects the bare task URL to the trailing-slash form", %{conn: conn, task: task} do
      conn = get(conn, "/preview/#{task.id}")

      assert redirected_to(conn) == "/preview/#{task.id}/"
    end
  end

  describe "authenticated, degraded" do
    setup :register_and_log_in_user

    test "nothing listening on the declared port renders the branded 502", %{conn: conn} do
      task = repo_task(dead_port())

      conn = get(conn, "/preview/#{task.id}/")

      assert conn.status == 502
      assert conn.resp_body =~ "Nothing is listening"
      assert conn.resp_body =~ "Terminal"
    end

    test "no preview port declared renders the hint page", %{conn: conn} do
      project = project_fixture()
      repository = repository_fixture(project.id)
      task = task_fixture(project.id, %{target: :repo, repository_id: repository.id})

      conn = get(conn, "/preview/#{task.id}/")

      assert conn.status == 404
      assert conn.resp_body =~ "No preview port declared"
    end

    test "unknown task renders the branded 404", %{conn: conn} do
      conn = get(conn, "/preview/999999/")

      assert conn.status == 404
      assert conn.resp_body =~ "Task not found"
    end
  end
end
