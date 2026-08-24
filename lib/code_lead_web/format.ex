defmodule CodeLeadWeb.Format do
  @moduledoc """
  Pure formatting helpers for money, token counts, timestamps, and short
  labels as they appear throughout the UI (`$1.24`, `183.5k`, `3m ago`).
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
  Label for the finalizer's forge link: the PR/MR it opened, the commit
  a merge landed, or the compare view it fell back to when no PR could
  be created.
  """
  @spec forge_link(atom() | nil) :: String.t()
  def forge_link(:pull_request), do: "PR"
  def forge_link(:merge_request), do: "MR"
  def forge_link(:commit), do: "Commit"
  def forge_link(_kind), do: "Compare"

  @doc """
  Neutral display text for a stored step summary. The survey summary
  stays technical in the DB — it is the match key for
  `CodeLead.Findings.survey_run_count/1` — and is translated only here.
  """
  def step_summary("repo survey: ok"), do: "Refinement completed"
  def step_summary("repo survey: " <> _status), do: "Refinement failed"
  def step_summary("task refinement: ok"), do: "Refinement completed"
  def step_summary("task refinement: " <> _status), do: "Refinement failed"
  def step_summary(summary), do: summary

  @doc """
  Label for the Approve button, stating the finalize mode that will
  actually run. `forge_known?` distinguishes a remote CodeLead can open
  a PR on from one where pushing the branch is all Done can do — the
  caller resolves it, because only it knows the repository.
  """
  @spec finalize_action(atom(), boolean()) :: String.t()
  def finalize_action(:pull_request, true), do: "Approve & open PR"
  def finalize_action(:pull_request, false), do: "Approve & push branch"
  def finalize_action(:merge, _forge_known?), do: "Approve & merge"
  def finalize_action(:squash, _forge_known?), do: "Approve & squash merge"
  def finalize_action(:artifact, _forge_known?), do: "Approve & hand over"
  def finalize_action(:commit_to_path, _forge_known?), do: "Approve & commit artifact"

  @doc """
  The same label for the mobile action bar, where only a verb fits.
  """
  @spec finalize_action_short(atom()) :: String.t()
  def finalize_action_short(:pull_request), do: "PR"
  def finalize_action_short(:merge), do: "Merge"
  def finalize_action_short(:squash), do: "Squash"
  def finalize_action_short(:artifact), do: "Finish"
  def finalize_action_short(:commit_to_path), do: "Commit"

  @doc """
  What Approve will do, spelled out — for the button's tooltip and the
  line under the task's finalize selector. `base_branch` names the
  branch a merge would write to.
  """
  @spec finalize_hint(atom(), String.t() | nil) :: String.t()
  def finalize_hint(:pull_request, _base) do
    "Commits any remainder, pushes the feature branch, and opens a PR/MR " <>
      "(or a compare link). Nothing is merged; the remote branch stays."
  end

  def finalize_hint(:merge, base) do
    "Pushes the feature branch, merges it into #{base_branch(base)}, pushes that, " <>
      "then deletes the remote branch."
  end

  def finalize_hint(:squash, base) do
    "Pushes the feature branch, lands it on #{base_branch(base)} as a single " <>
      "commit, then deletes the remote branch."
  end

  def finalize_hint(:artifact, _base) do
    "Marks the task complete and offers the task folder as a download. Nothing is pushed."
  end

  def finalize_hint(:commit_to_path, _base) do
    "Commits the task folder into the linked repository on its own branch and pushes it."
  end

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

  @doc """
  Time until a future reset, e.g. `\"2h 31m\"` when it lands within a day,
  `\"Tue 22:10\"` once it's far enough out that a bare countdown would run
  to absurd lengths.
  """
  @spec reset_in(DateTime.t() | nil) :: String.t()
  def reset_in(nil), do: "—"

  def reset_in(%DateTime{} = at) do
    seconds = DateTime.diff(at, DateTime.utc_now())

    cond do
      seconds <= 0 -> "now"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> countdown(seconds)
      true -> Calendar.strftime(at, "%a %H:%M")
    end
  end

  defp countdown(seconds) do
    minutes = div(seconds, 60)
    "#{div(minutes, 60)}h #{pad(rem(minutes, 60))}m"
  end

  @doc """
  Path rewritten relative to `root`, or nil when it falls outside `root` —
  the caller decides whether that means "keep the absolute form" or
  "ignore". The missing leading slash is what marks a path as belonging
  to the project.
  """
  @spec project_path(String.t(), String.t() | nil) :: String.t() | nil
  def project_path(_path, nil), do: nil

  def project_path(path, root) do
    expanded = Path.expand(root)

    case Path.relative_to(Path.expand(path, expanded), expanded) do
      "/" <> _outside -> nil
      relative -> relative
    end
  end

  defp base_branch(nil), do: "the default branch"
  defp base_branch(branch), do: branch
end
