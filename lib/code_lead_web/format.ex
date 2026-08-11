defmodule CodeLeadWeb.Format do
  @moduledoc """
  Pure formatting helpers for money, token counts, and timestamps as they
  appear throughout the UI (`$1.24`, `183.5k`, `3m ago`).
  """

  @doc "Formats cents as dollars, e.g. `123` -> `\"$1.23\"`."
  @spec cents(integer() | nil) :: String.t()
  def cents(nil), do: "$0.00"

  def cents(cost_cents) when is_integer(cost_cents) do
    dollars = cost_cents / 100
    "$#{:erlang.float_to_binary(dollars, decimals: 2)}"
  end

  @doc "Formats a token count compactly, e.g. `183_512` -> `\"183.5k\"`."
  @spec tokens(integer() | nil) :: String.t()
  def tokens(nil), do: "—"
  def tokens(0), do: "—"

  def tokens(n) when is_integer(n) and n >= 1_000_000 do
    "#{:erlang.float_to_binary(n / 1_000_000, decimals: 1)}M"
  end

  def tokens(n) when is_integer(n) and n >= 1_000 do
    "#{:erlang.float_to_binary(n / 1_000, decimals: 1)}k"
  end

  def tokens(n) when is_integer(n), do: Integer.to_string(n)

  @doc "Combined cost/token stat, e.g. `\"$1.24 · 183.5k\"`."
  @spec cost_tokens(integer() | nil, integer() | nil) :: String.t()
  def cost_tokens(cost_cents, token_count) do
    "#{cents(cost_cents)} · #{tokens(token_count)}"
  end

  @doc """
  Formats a run's cost for its billing mode: `:exact` is money billed,
  `:estimated` is the API-equivalent of a subscription run, `:free` is a
  locally hosted model that costs nothing.
  """
  @spec cost(integer() | nil, :exact | :estimated | :free) :: String.t()
  def cost(_cost_cents, :free), do: "—"
  def cost(cost_cents, :estimated), do: "~#{cents(cost_cents)} est"
  def cost(cost_cents, _exact), do: cents(cost_cents)

  @doc """
  Formats a millisecond duration, e.g. `134_000` -> `\"2m 14s\"`. Zero
  means unknown, not instant — runs recorded before durations were
  tracked, and sums over them, come through as 0.
  """
  @spec duration(integer() | nil) :: String.t()
  def duration(nil), do: "—"
  def duration(ms) when is_integer(ms) and ms <= 0, do: "—"
  def duration(ms) when is_integer(ms) and ms < 1_000, do: "#{ms}ms"

  def duration(ms) when is_integer(ms) and ms < 60_000 do
    "#{:erlang.float_to_binary(ms / 1_000, decimals: 1)}s"
  end

  def duration(ms) when is_integer(ms) and ms < 3_600_000 do
    seconds = div(ms, 1_000)
    "#{div(seconds, 60)}m #{pad(rem(seconds, 60))}s"
  end

  def duration(ms) when is_integer(ms) do
    minutes = div(ms, 60_000)
    "#{div(minutes, 60)}h #{pad(rem(minutes, 60))}m"
  end

  @doc """
  The full run stat, e.g. `\"$1.24 · 183.5k · 2m 14s\"`. Segments with
  nothing to say are dropped rather than rendered as a dash, so a
  subscription run reads `\"183.5k · 2m 14s\"` instead of `\"— · …\"`.
  """
  @spec run_stat(integer() | nil, integer() | nil, integer() | nil, :exact | :estimated | :free) ::
          String.t()
  def run_stat(cost_cents, token_count, duration_ms, cost_mode \\ :exact) do
    [cost(cost_cents, cost_mode), tokens(token_count), duration(duration_ms)]
    |> Enum.reject(&(&1 == "—"))
    |> case do
      [] -> "—"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: Integer.to_string(n)

  @doc "Relative time against now, e.g. `\"3m ago\"`."
  @spec relative(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def relative(nil), do: "—"

  def relative(%NaiveDateTime{} = naive) do
    naive |> DateTime.from_naive!("Etc/UTC") |> relative()
  end

  def relative(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds < 604_800 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(at, "%b %-d")
    end
  end

  @doc """
  Full timestamp for tooltips, e.g. `\"Aug 11, 2026 · 14:31 UTC\"`. The zone
  is spelled out because the client localizes it only when JavaScript runs.
  """
  @spec absolute(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def absolute(nil), do: "—"

  def absolute(%NaiveDateTime{} = naive) do
    naive |> DateTime.from_naive!("Etc/UTC") |> absolute()
  end

  def absolute(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %Y · %H:%M UTC")

  @doc "ISO8601 form of a timestamp, for client-side localization."
  @spec iso8601(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def iso8601(nil), do: nil

  def iso8601(%NaiveDateTime{} = naive) do
    naive |> DateTime.from_naive!("Etc/UTC") |> iso8601()
  end

  def iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)

  @doc "Short timestamp for event feeds, e.g. `\"14:31:02\"`."
  @spec time(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def time(nil), do: "—"
  def time(at), do: Calendar.strftime(at, "%H:%M:%S")
end
