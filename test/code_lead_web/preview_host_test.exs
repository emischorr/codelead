defmodule CodeLeadWeb.PreviewHostTest do
  # async: false — flips the globally configured preview gateway.
  use CodeLeadWeb.ConnCase, async: false

  import CodeLead.PreviewGatewayHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLeadWeb.PreviewHost.Auth

  @domain "preview.example.com"

  defp repo_task(preview_port) do
    project = project_fixture()
    repository = repository_fixture(project.id, %{preview_port: preview_port})
    task_fixture(project.id, %{target: :repo, repository_id: repository.id})
  end

  defp task_with_upstream do
    upstream =
      start_supervised!(
        {Bandit, plug: CodeLead.PreviewUpstreamPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(upstream)
    repo_task(port)
  end

  defp preview_url(task, path \\ "/") do
    "http://task-#{task.id}.#{@domain}#{path}"
  end

  defp token(task_id), do: Auth.sign(CodeLeadWeb.Endpoint, task_id)

  # The handshake, as a browser would ride it: token GET → 302 to `/` +
  # session cookie; the cookie authenticates the follow-up request.
  defp handshake(conn, task) do
    conn = get(conn, preview_url(task, "/?_preview_auth=#{token(task.id)}"))

    assert redirected_to(conn) == "/"
    assert [cookie] = get_resp_header(conn, "set-cookie")
    assert cookie =~ "_clp_session="

    session_cookie = cookie |> String.split(";") |> hd()

    build_conn() |> put_req_header("cookie", session_cookie)
  end

  describe "subdomain gateway active" do
    setup do
      subdomain_gateway!(domain: @domain, url: [scheme: "http", port: 80])
      :ok
    end

    test "a visit without token or session is refused with the branded page", %{conn: conn} do
      task = repo_task(4321)

      conn = get(conn, preview_url(task))

      assert conn.status == 401
      assert conn.resp_body =~ "Open this preview from CodeLead"
    end

    test "the token handshake lands an authenticated, proxied session", %{conn: conn} do
      task = task_with_upstream()

      authed = handshake(conn, task)
      conn = get(authed, preview_url(task, "/info?probe=1"))

      assert conn.status == 200
      assert conn.resp_body =~ "GET /info?probe=1"
    end

    test "an expired token is refused", %{conn: conn} do
      task = repo_task(4321)

      stale =
        Phoenix.Token.sign(CodeLeadWeb.Endpoint, "preview host", %{task_id: task.id},
          signed_at: System.system_time(:second) - 120
        )

      conn = get(conn, preview_url(task, "/?_preview_auth=#{stale}"))

      assert conn.status == 401
    end

    test "a token minted for another task is refused", %{conn: conn} do
      task = repo_task(4321)
      other = repo_task(4322)

      conn = get(conn, preview_url(task, "/?_preview_auth=#{token(other.id)}"))

      assert conn.status == 401
    end

    test "responses pass through without namespacing or location rewriting", %{conn: conn} do
      task = task_with_upstream()
      authed = handshake(conn, task)

      set_cookie = get(authed, preview_url(task, "/setcookie"))
      cookies = get_resp_header(set_cookie, "set-cookie")
      assert Enum.any?(cookies, &String.starts_with?(&1, "sid=abc"))
      refute Enum.any?(cookies, &String.contains?(&1, "_clp#{task.id}_"))

      redirect = get(authed, preview_url(task, "/redirect"))
      assert get_resp_header(redirect, "location") == ["/after"]
    end

    test "the upstream sees its own cookies but never the preview session cookie", %{conn: conn} do
      task = task_with_upstream()
      authed = handshake(conn, task)

      [session_cookie] = get_req_header(authed, "cookie")

      conn =
        authed
        |> put_req_header("cookie", session_cookie <> "; sid=abc; theme=dark")
        |> get(preview_url(task, "/info"))

      assert conn.resp_body =~ "cookie: sid=abc; theme=dark"
      refute conn.resp_body =~ "_clp_session"
    end

    test "hosts under the wildcard that are not task hosts fall through to the app" do
      for host_url <- [
            "http://#{@domain}/",
            "http://task-x.#{@domain}/",
            "http://a.task-1.#{@domain}/"
          ] do
        conn = get(build_conn(), host_url)

        # The app router answered (setup/login redirect or page), not the
        # preview pipeline's branded 401.
        refute conn.status == 401
        assert conn.private[:phoenix_router] == CodeLeadWeb.Router
      end
    end

    test "stale /preview/ path URLs are refused with a pointer to the launch route" do
      user_conn = log_in_user(build_conn(), CodeLead.AccountsFixtures.user_fixture())
      task = repo_task(4321)

      conn = get(user_conn, "/preview/#{task.id}/")

      assert conn.status == 404
      assert conn.resp_body =~ "subdomain previews"
      assert conn.resp_body =~ "/preview/launch/#{task.id}"
    end

    test "the launch route redirects onto the subdomain with a verifiable token" do
      user_conn = log_in_user(build_conn(), CodeLead.AccountsFixtures.user_fixture())
      task = repo_task(4321)

      conn = get(user_conn, "/preview/launch/#{task.id}")

      assert redirected_to(conn) =~ "http://task-#{task.id}.#{@domain}/?_preview_auth="

      token =
        conn
        |> redirected_to()
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("_preview_auth")

      assert {:ok, %{task_id: task_id}} =
               Phoenix.Token.verify(CodeLeadWeb.Endpoint, "preview host", token, max_age: 60)

      assert task_id == task.id
    end
  end

  describe "path gateway (default)" do
    test "task-shaped hosts fall through to the app when no preview domain is set", %{conn: conn} do
      conn = get(conn, "http://task-1.#{@domain}/")

      refute conn.status == 401
      assert conn.private[:phoenix_router] == CodeLeadWeb.Router
    end
  end
end
