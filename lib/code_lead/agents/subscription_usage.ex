defmodule CodeLead.Agents.SubscriptionUsage do
  @moduledoc """
  Best-effort read of a Claude subscription's 5-hour and weekly rate-limit
  usage. Anthropic publishes no API for this — the only known signal is the
  undocumented `anthropic-ratelimit-unified-*` response headers that Claude
  Code's own status line is fed from internally, which appear on any
  OAuth-authenticated `/v1/messages` response. This module triggers one by
  issuing the cheapest possible completion (a one-token Haiku reply).

  Anthropic can rename or remove these headers without notice, so every
  parse step degrades to "no data" rather than raising — callers should
  never treat a `:error` here as anything more than "try again later".
  """

  @receive_timeout 15_000
  @ping_model "claude-haiku-4-5"

  @type window :: %{utilization: float(), resets_at: DateTime.t() | nil}
  @type t :: %{five_hour: window() | nil, seven_day: window() | nil}

  @doc """
  Issues a minimal completion with the given OAuth bearer token and parses
  the rate-limit windows off the response headers.
  """
  @spec fetch(String.t() | nil) :: {:ok, t()} | :error
  def fetch(token) when is_binary(token) and token != "" do
    request(
      url: "https://api.anthropic.com/v1/messages",
      headers: [
        {"authorization", "Bearer " <> token},
        {"anthropic-version", "2023-06-01"},
        {"anthropic-beta", "oauth-2025-04-20"}
      ],
      json: %{
        model: @ping_model,
        max_tokens: 1,
        messages: [%{role: :user, content: "."}]
      }
    )
    |> parse()
  end

  def fetch(_token), do: :error

  defp request(opts) do
    opts =
      Keyword.merge(
        [method: :post, receive_timeout: @receive_timeout],
        opts ++ Application.get_env(:code_lead, :subscription_usage_req_options, [])
      )

    Req.request(opts)
  end

  # The rate-limit headers ride on every response — including 4xx/5xx ones
  # — since reporting the limit is the point of them, so parsing never
  # branches on `resp.status`.
  defp parse({:ok, %Req.Response{} = resp}) do
    case {window(resp, "5h"), window(resp, "7d")} do
      {nil, nil} -> :error
      {five_hour, seven_day} -> {:ok, %{five_hour: five_hour, seven_day: seven_day}}
    end
  end

  defp parse({:error, _exception}), do: :error

  defp window(resp, bucket) do
    with [raw_utilization] <-
           Req.Response.get_header(resp, "anthropic-ratelimit-unified-#{bucket}-utilization"),
         {utilization, ""} <- Float.parse(raw_utilization) do
      %{utilization: utilization, resets_at: reset_at(resp, bucket)}
    else
      _ -> nil
    end
  end

  defp reset_at(resp, bucket) do
    with [raw_reset] <-
           Req.Response.get_header(resp, "anthropic-ratelimit-unified-#{bucket}-reset"),
         {unix, ""} <- Integer.parse(raw_reset),
         {:ok, datetime} <- DateTime.from_unix(unix) do
      datetime
    else
      _ -> nil
    end
  end
end
