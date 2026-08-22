defmodule CodeLeadWeb.Plugs.PreviewLoopGuardTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias CodeLeadWeb.Plugs.PreviewLoopGuard
  alias CodeLeadWeb.PreviewProxy.LoopBreaker

  setup context do
    name = :"guard_breaker_#{:erlang.phash2(context.test)}"

    start_supervised!(
      {LoopBreaker, name: name, threshold: 3, window_ms: 500, pause_ms: 500, sweep_ms: 200},
      id: name
    )

    %{opts: PreviewLoopGuard.init(breaker: name)}
  end

  defp navigate(path, headers) do
    Enum.reduce(headers, conn(:get, path), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> init_test_session(user_token: "token")
  end

  defp run(path, opts, headers \\ [{"sec-fetch-dest", "document"}]) do
    path |> navigate(headers) |> PreviewLoopGuard.call(opts)
  end

  # Drives `count` navigations and returns the last conn.
  defp run_many(path, opts, count, headers \\ [{"sec-fetch-dest", "document"}]) do
    Enum.reduce(1..count, nil, fn _i, _acc -> run(path, opts, headers) end)
  end

  describe "trips on a reload loop" do
    test "serves the diagnostic on the Nth document navigation", %{opts: opts} do
      refute run_many("/preview/7/", opts, 2).halted

      conn = run("/preview/7/", opts)

      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body =~ "This preview kept reloading itself"
      assert conn.resp_body =~ "LiveSocket"
    end

    test "counts a nested path too", %{opts: opts} do
      conn = run_many("/preview/7/bikes", opts, 3)

      assert conn.halted
    end
  end

  describe "does not trip" do
    test "on subresources, whatever the count", %{opts: opts} do
      for dest <- ~w(style script font image empty iframe) do
        conn = run_many("/preview/7/a.css", opts, 10, [{"sec-fetch-dest", dest}])
        refute conn.halted, "#{dest} should never count"
      end
    end

    test "on a request the browser marked as an explicit reload", %{opts: opts} do
      for value <- ["max-age=0", "no-cache"] do
        headers = [{"sec-fetch-dest", "document"}, {"cache-control", value}]
        refute run_many("/preview/7/", opts, 20, headers).halted
      end
    end

    test "when the navigations walk different paths", %{opts: opts} do
      for path <- ~w(/preview/7/a /preview/7/b /preview/7/a /preview/7/b /preview/7/a) do
        refute run(path, opts).halted
      end
    end

    test "on an XHR whose Accept happens to include text/html", %{opts: opts} do
      headers = [{"sec-fetch-dest", "empty"}, {"accept", "text/html, */*"}]
      refute run_many("/preview/7/api", opts, 20, headers).halted
    end

    test "on the bare-path leg the controller redirects", %{opts: opts} do
      # `/preview/7` is 302'd to `/preview/7/`; counting it would
      # double-count every bare-path navigation.
      refute run_many("/preview/7", opts, 20).halted
    end

    test "on a POST", %{opts: opts} do
      conn =
        Enum.reduce(1..20, nil, fn _i, _acc ->
          :post
          |> conn("/preview/7/")
          |> put_req_header("sec-fetch-dest", "document")
          |> init_test_session(user_token: "token")
          |> PreviewLoopGuard.call(opts)
        end)

      refute conn.halted
    end

    test "on the launch route", %{opts: opts} do
      refute run_many("/preview/launch/7", opts, 20).halted
    end

    test "on a path outside the preview mount", %{opts: opts} do
      refute run_many("/tasks/7", opts, 20).halted
    end

    test "when no Sec-Fetch-Dest and a non-HTML Accept", %{opts: opts} do
      headers = [{"accept", "application/json"}]
      refute run_many("/preview/7/api", opts, 20, headers).halted
    end

    test "when the breaker is disarmed instance-wide", %{opts: opts} do
      Application.put_env(:code_lead, :preview_loop_breaker, false)
      on_exit(fn -> Application.delete_env(:code_lead, :preview_loop_breaker) end)

      refute run_many("/preview/7/", opts, 20).halted
    end
  end

  describe "counting without Sec-Fetch-Dest" do
    test "an HTML Accept still counts as a navigation", %{opts: opts} do
      headers = [{"accept", "text/html,application/xhtml+xml"}]

      assert run_many("/preview/7/", opts, 3, headers).halted
    end
  end

  describe "bypass" do
    test "pauses the check and redirects to the clean URL", %{opts: opts} do
      assert run_many("/preview/7/", opts, 3).halted

      conn = run("/preview/7/?#{URI.encode_query(%{"_clp_loop_bypass" => "1"})}", opts)

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/preview/7/"]

      # And the loop is allowed through afterwards.
      for _ <- 1..10, do: refute(run("/preview/7/", opts).halted)
    end

    test "preserves the app's own query params while stripping the flag", %{opts: opts} do
      conn = run("/preview/7/?a=1&_clp_loop_bypass=1", opts)

      assert get_resp_header(conn, "location") == ["/preview/7/?a=1"]
    end
  end
end
