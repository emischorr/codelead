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

  @doc "Short timestamp for event feeds, e.g. `\"14:31:02\"`."
  @spec time(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def time(nil), do: "—"
  def time(at), do: Calendar.strftime(at, "%H:%M:%S")
end
