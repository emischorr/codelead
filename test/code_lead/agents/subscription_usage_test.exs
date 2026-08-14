defmodule CodeLead.Agents.SubscriptionUsageTest do
  use ExUnit.Case, async: true

  alias CodeLead.Agents.SubscriptionUsage

  defp stub_response(fun), do: Req.Test.stub(CodeLead.SubscriptionUsageStub, fun)

  defp put_rate_limit_headers(conn) do
    conn
    |> Plug.Conn.put_resp_header("anthropic-ratelimit-unified-5h-utilization", "0.235")
    |> Plug.Conn.put_resp_header("anthropic-ratelimit-unified-5h-reset", "1738425600")
    |> Plug.Conn.put_resp_header("anthropic-ratelimit-unified-7d-utilization", "0.812")
    |> Plug.Conn.put_resp_header("anthropic-ratelimit-unified-7d-reset", "1738857600")
  end

  describe "fetch/1" do
    test "parses both windows off the response headers" do
      stub_response(fn conn ->
        conn |> put_rate_limit_headers() |> Req.Test.json(%{"content" => []})
      end)

      assert {:ok, usage} = SubscriptionUsage.fetch("oat-test-token")
      assert usage.five_hour.utilization == 0.235
      assert usage.five_hour.resets_at == DateTime.from_unix!(1_738_425_600)
      assert usage.seven_day.utilization == 0.812
      assert usage.seven_day.resets_at == DateTime.from_unix!(1_738_857_600)
    end

    test "sends the OAuth bearer, beta header, and a minimal one-token ping" do
      stub_response(fn conn ->
        assert ["Bearer oat-test-token"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["oauth-2025-04-20"] = Plug.Conn.get_req_header(conn, "anthropic-beta")
        assert ["2023-06-01"] = Plug.Conn.get_req_header(conn, "anthropic-version")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["max_tokens"] == 1
        assert [%{"role" => "user", "content" => "."}] = decoded["messages"]

        conn |> put_rate_limit_headers() |> Req.Test.json(%{"content" => []})
      end)

      assert {:ok, _usage} = SubscriptionUsage.fetch("oat-test-token")
    end

    test "returns :error when no rate-limit headers are present" do
      stub_response(fn conn -> Req.Test.json(conn, %{"content" => []}) end)

      assert SubscriptionUsage.fetch("oat-test-token") == :error
    end

    test "returns :error on a malformed header value, without crashing" do
      stub_response(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("anthropic-ratelimit-unified-5h-utilization", "not-a-number")
        |> Req.Test.json(%{"content" => []})
      end)

      assert SubscriptionUsage.fetch("oat-test-token") == :error
    end

    test "parses headers even on a non-200 response" do
      stub_response(fn conn ->
        conn
        |> put_rate_limit_headers()
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, ~s({"error": "rate limited"}))
      end)

      assert {:ok, usage} = SubscriptionUsage.fetch("oat-test-token")
      assert usage.five_hour.utilization == 0.235
    end

    test "returns :error on a network failure" do
      stub_response(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert SubscriptionUsage.fetch("oat-test-token") == :error
    end

    test "returns :error for a blank or nil token without making a request" do
      assert SubscriptionUsage.fetch(nil) == :error
      assert SubscriptionUsage.fetch("") == :error
    end
  end
end
