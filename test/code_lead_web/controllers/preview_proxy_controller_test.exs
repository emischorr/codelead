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

  # The conn also carries the harness's own login cookie; only the
  # namespaced ones came out of the proxy.
  defp proxied_cookies(conn, task) do
    conn
    |> Plug.Conn.get_resp_header("set-cookie")
    |> Enum.filter(&String.starts_with?(&1, "_clp#{task.id}_"))
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

    test "evicts a shadow session cookie planted under the mount", %{conn: conn} do
      task = repo_task(4321)

      conn =
        conn
        |> put_req_header("cookie", "_code_lead_key=real; _code_lead_key=shadow")
        |> get("/preview/#{task.id}/")

      assert conn.status == 401
      assert conn.resp_body =~ "Restoring your session"

      assert [eviction] = get_resp_header(conn, "set-cookie")
      assert eviction =~ "_code_lead_key=;"
      assert eviction =~ "path=/preview/#{task.id}"
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

    test "forwards only this task's namespaced cookies", %{conn: conn, task: task} do
      conn =
        conn
        |> put_req_header(
          "cookie",
          "_code_lead_key=secret; _code_lead_web_user_remember_me=tok; " <>
            "devtool=1; _clp#{task.id}_devtool=2"
        )
        |> get("/preview/#{task.id}/info")

      assert conn.resp_body =~ "cookie: devtool=2"
      refute conn.resp_body =~ "_code_lead_key"
      refute conn.resp_body =~ "_code_lead_web_user_remember_me"
      refute conn.resp_body =~ "devtool=1"
    end

    test "namespaces upstream cookies onto the mount", %{conn: conn, task: task} do
      conn = get(conn, "/preview/#{task.id}/setcookie")

      cookies = proxied_cookies(conn, task)

      # Two upstream cookies must survive as two headers — merging by
      # name would collapse them into the last one.
      assert length(cookies) == 2

      assert "_clp#{task.id}_sid=abc; Path=/preview/#{task.id}; HttpOnly" in cookies
      assert "_clp#{task.id}_theme=dark; Path=/preview/#{task.id}/admin; HttpOnly" in cookies
    end

    test "a previewed app cannot clobber the host session cookie", %{conn: conn, task: task} do
      conn = get(conn, "/preview/#{task.id}/clobber")

      assert proxied_cookies(conn, task) == [
               "_clp#{task.id}__code_lead_key=junk; Path=/preview/#{task.id}; HttpOnly"
             ]

      # Nothing landed on the host's own session cookie — the only
      # `_code_lead_key=` the browser sees is the harness's real login.
      refute Enum.any?(get_resp_header(conn, "set-cookie"), &(&1 =~ ~r/^_code_lead_key=junk/))
    end

    test "drops Domain and http-void attributes from upstream cookies", %{conn: conn, task: task} do
      conn = get(conn, "/preview/#{task.id}/fancycookie")

      assert proxied_cookies(conn, task) == [
               "_clp#{task.id}_sid=abc; Path=/preview/#{task.id}; HttpOnly"
             ]
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

  # Async-safe without any config juggling: the breaker keys on
  # {task id, hashed session token}, and both are fresh per test.
  describe "reload loop breaker" do
    setup [:register_and_log_in_user, :task_with_upstream]

    defp navigate(conn, path, headers \\ [{"sec-fetch-dest", "document"}]) do
      Enum.reduce(headers, conn, fn {name, value}, acc ->
        Plug.Conn.put_req_header(acc, name, value)
      end)
      |> get(path)
    end

    test "breaks the loop with the diagnostic instead of proxying", %{conn: conn, task: task} do
      for _ <- 1..4, do: navigate(conn, "/preview/#{task.id}/")

      last = navigate(conn, "/preview/#{task.id}/")

      assert last.status == 200
      assert last.resp_body =~ "This preview kept reloading itself"
      # The upstream echo is absent — it was never dialed.
      refute last.resp_body =~ "GET /"
    end

    test "the bypass link lets it through again", %{conn: conn, task: task} do
      for _ <- 1..5, do: navigate(conn, "/preview/#{task.id}/")

      bounce = navigate(conn, "/preview/#{task.id}/?_clp_loop_bypass=1")

      assert bounce.status == 302
      assert redirected_to(bounce) == "/preview/#{task.id}/"

      for _ <- 1..8 do
        assert navigate(conn, "/preview/#{task.id}/info").status == 200
      end
    end

    test "subresources never trip it", %{conn: conn, task: task} do
      for _ <- 1..20 do
        resp = navigate(conn, "/preview/#{task.id}/info", [{"sec-fetch-dest", "empty"}])
        assert resp.status == 200
        assert resp.resp_body =~ "GET /info"
      end
    end

    test "an explicit browser refresh never trips it", %{conn: conn, task: task} do
      headers = [{"sec-fetch-dest", "document"}, {"cache-control", "max-age=0"}]

      for _ <- 1..20 do
        assert navigate(conn, "/preview/#{task.id}/info", headers).status == 200
      end
    end

    test "the bare-path redirect leg is not counted", %{conn: conn, task: task} do
      for _ <- 1..20 do
        assert navigate(conn, "/preview/#{task.id}").status == 302
      end
    end
  end
end
