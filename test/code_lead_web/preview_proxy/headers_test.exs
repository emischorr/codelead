defmodule CodeLeadWeb.PreviewProxy.HeadersTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias CodeLeadWeb.PreviewProxy.Headers
  alias CodeLeadWeb.PreviewProxy.Policy

  @upstream %{host: "127.0.0.1", port: 4000}

  defp policy, do: Policy.path(7)

  defp forwarded(cookie_headers, policy \\ policy(), path \\ "/preview/7/") do
    cookie_headers
    |> Enum.reduce(conn(:get, path), fn value, conn ->
      %{conn | req_headers: conn.req_headers ++ [{"cookie", value}]}
    end)
    |> Headers.request_headers(@upstream, policy)
    |> Enum.filter(&match?({"cookie", _value}, &1))
  end

  defp namespaced(set_cookie, scheme \\ :http) do
    [{"set-cookie", set_cookie}]
    |> Headers.response_headers(policy(), scheme)
    |> Enum.map(fn {"set-cookie", value} -> value end)
  end

  defp attributes(set_cookie) do
    set_cookie |> String.split(";") |> Enum.map(&String.trim/1) |> tl()
  end

  describe "Policy.path/1" do
    test "derives the mount path and a prefix-free cookie namespace" do
      assert %Policy{mount_path: "/preview/7", cookie_prefix: "_clp7_", rewrite_location?: true} =
               Policy.path(7)

      # The trailing underscore is what keeps task 4 from prefixing 42.
      refute String.starts_with?(Policy.path(42).cookie_prefix, Policy.path(4).cookie_prefix)
    end
  end

  describe "request_headers/3 cookies" do
    test "forwards only this task's cookies, with the namespace peeled off" do
      assert forwarded(["_clp7_sid=abc; devtool=1"]) == [{"cookie", "sid=abc"}]
    end

    test "drops CodeLead's session and remember-me cookies" do
      assert forwarded(["_code_lead_key=secret; _code_lead_web_user_remember_me=tok"]) == []
    end

    test "drops another task's cookies" do
      assert forwarded(["_clp8_sid=other; _clp70_sid=other"]) == []
    end

    test "drops the header entirely when nothing survives" do
      assert forwarded(["devtool=1; theme=dark"]) == []
    end

    test "rewrites every cookie header, not just the first" do
      assert forwarded(["_clp7_a=1; junk=x", "_clp7_b=2"]) == [
               {"cookie", "a=1"},
               {"cookie", "b=2"}
             ]
    end

    test "strips the namespace exactly once" do
      assert forwarded(["_clp7__clp8_x=1"]) == [{"cookie", "_clp8_x=1"}]
    end

    test "keeps values containing = intact" do
      assert forwarded([~s(_clp7_sid="a=b==")]) == [{"cookie", ~s(sid="a=b==")}]
    end

    test "drops a bare name with no value" do
      assert forwarded(["_clp7_sid"]) == []
    end
  end

  describe "ws_request_headers/3" do
    test "inherits the cookie filtering and drops handshake fields" do
      headers =
        conn(:get, "/preview/7/socket")
        |> put_req_header("cookie", "_clp7_sid=abc; _code_lead_key=secret")
        |> put_req_header("sec-websocket-key", "key")
        |> put_req_header("sec-websocket-version", "13")
        |> Headers.ws_request_headers(@upstream, policy())

      assert {"cookie", "sid=abc"} in headers
      refute List.keyfind(headers, "sec-websocket-key", 0)
      refute List.keyfind(headers, "host", 0)
    end
  end

  describe "response_headers/3 cookies" do
    test "prefixes the name and folds Path=/ onto the mount" do
      assert namespaced("sid=abc; Path=/") == ["_clp7_sid=abc; Path=/preview/7"]
    end

    test "maps a sub-path under the mount" do
      assert namespaced("sid=abc; Path=/admin") == ["_clp7_sid=abc; Path=/preview/7/admin"]
    end

    test "forces the mount when Path is absent or relative" do
      assert namespaced("sid=abc") == ["_clp7_sid=abc; Path=/preview/7"]
      assert namespaced("sid=abc; Path=admin") == ["_clp7_sid=abc; Path=/preview/7"]
    end

    test "rewrites every set-cookie independently" do
      headers =
        Headers.response_headers(
          [{"set-cookie", "a=1; Path=/"}, {"set-cookie", "b=2; Path=/"}],
          policy(),
          :http
        )

      assert headers == [
               {"set-cookie", "_clp7_a=1; Path=/preview/7"},
               {"set-cookie", "_clp7_b=2; Path=/preview/7"}
             ]
    end

    test "drops Domain so the cookie stays host-only" do
      [cookie] = namespaced("sid=abc; Path=/; Domain=example.com")

      refute attributes(cookie) |> Enum.any?(&String.starts_with?(String.downcase(&1), "domain"))
    end

    test "drops Secure, Partitioned and SameSite=None over plain http" do
      [cookie] = namespaced("sid=abc; Path=/; Secure; Partitioned; SameSite=None")

      assert attributes(cookie) == ["Path=/preview/7"]
    end

    test "keeps Secure, Partitioned and SameSite=None over https" do
      [cookie] = namespaced("sid=abc; Path=/; Secure; Partitioned; SameSite=None", :https)

      assert attributes(cookie) == ["Path=/preview/7", "Secure", "Partitioned", "SameSite=None"]
    end

    test "keeps SameSite=Lax in both schemes" do
      assert ["_clp7_sid=abc; Path=/preview/7; SameSite=Lax"] =
               namespaced("sid=abc; Path=/; SameSite=Lax")

      assert ["_clp7_sid=abc; Path=/preview/7; SameSite=Lax"] =
               namespaced("sid=abc; Path=/; SameSite=Lax", :https)
    end

    test "preserves HttpOnly, Max-Age and a comma-bearing Expires" do
      [cookie] =
        namespaced("sid=; Path=/; Max-Age=0; Expires=Wed, 21 Oct 2015 07:28:00 GMT; HttpOnly")

      assert attributes(cookie) == [
               "Path=/preview/7",
               "Max-Age=0",
               "Expires=Wed, 21 Oct 2015 07:28:00 GMT",
               "HttpOnly"
             ]

      # Rejoined it is byte-identical to what the upstream wrote.
      assert cookie ==
               "_clp7_sid=; Path=/preview/7; Max-Age=0; Expires=Wed, 21 Oct 2015 07:28:00 GMT; HttpOnly"
    end

    test "renaming defuses __Host-, which round-trips back to the upstream" do
      [cookie] = namespaced("__Host-session=x; Path=/; Secure; HttpOnly", :https)

      assert cookie == "_clp7___Host-session=x; Path=/preview/7; Secure; HttpOnly"
      assert forwarded(["_clp7___Host-session=x"]) == [{"cookie", "__Host-session=x"}]
    end

    test "keeps values containing = byte-for-byte" do
      assert namespaced(~s(sid="a=b=="; Path=/)) == [~s(_clp7_sid="a=b=="; Path=/preview/7)]
    end

    test "drops a set-cookie with no name" do
      assert namespaced("=orphan; Path=/") == []
      assert namespaced("novalue; Path=/") == []
    end

    test "round-trips a cookie back to the name and value the upstream set" do
      [cookie] = namespaced("sid=abc; Path=/")
      [pair | _attrs] = String.split(cookie, ";")

      assert forwarded([pair]) == [{"cookie", "sid=abc"}]
    end
  end

  describe "response_headers/3 non-cookie headers" do
    test "still rewrites root-relative locations and passes the rest through" do
      headers =
        Headers.response_headers(
          [
            {"location", "/after"},
            {"location", "https://elsewhere.test/x"},
            {"x-upstream", "yes"},
            {"keep-alive", "timeout=5"},
            {"content-length", "3"}
          ],
          policy(),
          :http
        )

      assert headers == [
               {"location", "/preview/7/after"},
               {"location", "https://elsewhere.test/x"},
               {"x-upstream", "yes"}
             ]
    end
  end

  describe "subdomain policy" do
    defp subdomain_forwarded(cookie_headers) do
      forwarded(cookie_headers, Policy.subdomain(), "/")
    end

    test "forwards the cookie jar verbatim, minus the preview session cookie" do
      assert subdomain_forwarded(["sid=abc; theme=dark"]) == [{"cookie", "sid=abc; theme=dark"}]

      assert subdomain_forwarded(["_clp_session=secret; sid=abc"]) == [{"cookie", "sid=abc"}]
      assert subdomain_forwarded(["_clp_session=secret"]) == []
    end

    test "does not stamp x-forwarded-prefix" do
      headers =
        conn(:get, "/")
        |> Headers.request_headers(@upstream, Policy.subdomain())

      refute List.keyfind(headers, "x-forwarded-prefix", 0)
      assert {"x-forwarded-proto", "http"} = List.keyfind(headers, "x-forwarded-proto", 0)
    end

    test "passes set-cookie through untouched" do
      headers =
        Headers.response_headers(
          [{"set-cookie", "sid=abc; Path=/admin; Domain=example.com; Secure; SameSite=None"}],
          Policy.subdomain(),
          :http
        )

      assert headers == [
               {"set-cookie", "sid=abc; Path=/admin; Domain=example.com; Secure; SameSite=None"}
             ]
    end

    test "leaves root-relative locations alone" do
      headers =
        Headers.response_headers(
          [{"location", "/after"}, {"keep-alive", "timeout=5"}],
          Policy.subdomain(),
          :http
        )

      assert headers == [{"location", "/after"}]
    end
  end
end
