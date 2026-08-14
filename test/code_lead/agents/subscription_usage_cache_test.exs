defmodule CodeLead.Agents.SubscriptionUsageCacheTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AgentsFixtures

  alias CodeLead.Agents.SubscriptionUsageCache

  defp stub_response(fun), do: Req.Test.stub(CodeLead.SubscriptionUsageStub, fun)

  defp start_cache! do
    cache = start_supervised!({SubscriptionUsageCache, name: :"cache_#{System.unique_integer()}"})
    Ecto.Adapters.SQL.Sandbox.allow(CodeLead.Repo, self(), cache)
    cache
  end

  defp put_rate_limit_headers(conn) do
    conn
    |> Plug.Conn.put_resp_header("anthropic-ratelimit-unified-5h-utilization", "0.1")
    |> Plug.Conn.put_resp_header("anthropic-ratelimit-unified-5h-reset", "1738425600")
    |> Plug.Conn.put_resp_header("anthropic-ratelimit-unified-7d-utilization", "0.4")
    |> Plug.Conn.put_resp_header("anthropic-ratelimit-unified-7d-reset", "1738857600")
  end

  test "reports nil when no subscription provider is configured" do
    cache = start_cache!()

    SubscriptionUsageCache.refresh_now(cache)

    assert SubscriptionUsageCache.current(cache) == nil
  end

  test "reports a snapshot for a configured provider after refreshing" do
    provider_fixture(%{
      name: "Alice's Max plan",
      kind: :anthropic_subscription,
      config: %{"oauth_token" => "oat-abc"}
    })

    stub_response(fn conn ->
      conn |> put_rate_limit_headers() |> Req.Test.json(%{"content" => []})
    end)

    cache = start_cache!()
    SubscriptionUsageCache.refresh_now(cache)

    assert %{provider_name: "Alice's Max plan"} = usage = SubscriptionUsageCache.current(cache)
    assert usage.five_hour.utilization == 0.1
    assert usage.seven_day.utilization == 0.4
  end

  test "keeps no entry when the fetch fails, without crashing" do
    provider_fixture(%{
      kind: :anthropic_subscription,
      config: %{"oauth_token" => "oat-abc"}
    })

    stub_response(fn conn -> Req.Test.json(conn, %{"content" => []}) end)

    cache = start_cache!()
    SubscriptionUsageCache.refresh_now(cache)

    assert SubscriptionUsageCache.current(cache) == nil
  end

  test "never polls non-subscription providers" do
    provider_fixture(%{kind: :anthropic_api, config: %{"api_key" => "sk-x"}})

    stub_response(fn _conn -> flunk("should not have made a request") end)

    cache = start_cache!()
    SubscriptionUsageCache.refresh_now(cache)

    assert SubscriptionUsageCache.current(cache) == nil
  end
end
