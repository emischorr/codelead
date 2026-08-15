defmodule CodeLead.License do
  @moduledoc """
  License entitlement seam — the one place that decides what this
  instance may do.

  Almost everything is free. `@gated_features` lists the exceptions, and
  `feature_enabled?/1` answers `true` for every name absent from it, so
  an instance with no `LICENSE_KEY` runs as `:community` with only those
  few things withheld.

  Gated today:

    * `:container_execution_env` — running a task in a sibling container
      (`tasks.execution_env == :container`); see ADR-0004.

  Monetizing a feature is a *data* change rather than a hunt through the
  app for places to add a check:

    1. add the feature's atom to `@gated_features`
    2. call `feature_enabled?/1` at the call site **and** in the
       authoritative server-side action — UI hiding is cosmetic
    3. grant it, either centrally via `tier_baseline/1` or per key

  Call sites do not change when a feature moves from free to paid.

  ## Tiers

  Grants are not community-vs-everything. A key names a `tier`, and the
  resolved grant is that **tier's baseline overlaid with the key's own
  explicit grants** (`merge_grant/3`): features union, limits merged with
  the key winning. So `tier_baseline/1` evolves what a tier means for
  every key already issued against it — no reissue — while a single
  bespoke deal is expressible as explicit `features`/`limits` on one key.

  `:owner` is the maintainer's own tier: its baseline is `@gated_features`
  itself, so it picks up each new gated feature without anyone reissuing
  the key. It grants **features only** — `limit/2` still hands an owner
  instance the caller's default, because there is no generic way to say
  "every cap raised". A raised cap needs `--limits` on the key like any
  other.

  ## Failure is always downward

  Missing key, bad signature, expired, malformed, unknown tier: every one
  degrades to `:community` with a warning. A lapsed commercial key must
  not brick a self-hosted instance. The key itself is never logged.

  ## Unknown names are dropped

  Feature and tier names in a key become atoms with
  `String.to_existing_atom/1`, so a key minted against a *newer* build can
  name things this build has never heard of without raising or growing the
  atom table — the unknowns are simply dropped.

  Which is why listing a feature in `@gated_features` is what brings its
  atom into existence: a name no build has compiled cannot be granted,
  and a feature nobody gates does not need granting.

  See `docs/licensing.md`.
  """

  alias CodeLead.License.Entitlements
  alias CodeLead.License.Source

  require Logger

  @cache_key {__MODULE__, :entitlements}

  # ── THE SEAM ─────────────────────────────────────────────────────────
  # Anything absent here is free. Adding an atom is what turns a feature
  # into a paid one — and what brings its name into the atom table, so a
  # key can name it at all.
  @gated_features MapSet.new([
                    :container_execution_env
                  ])

  # The whole gated set, resolved at compile time for `tier_baseline(:owner)`.
  # Gating a new feature therefore grants it to owner instances on the next
  # boot, with no key reissued.
  @owner_features MapSet.to_list(@gated_features)

  @typedoc "What a tier grants before a key's own extras are merged in."
  @type grant :: %{features: [atom()], limits: %{optional(atom()) => term()}}

  @doc """
  What a tier grants on its own.

  Central and in code on purpose: editing a baseline changes what that
  tier means for every key already in the field, on next boot.
  """
  @spec tier_baseline(atom()) :: grant()
  def tier_baseline(:community), do: %{features: [], limits: %{}}

  # The maintainer's own tier: everything gated, always, including
  # features added after the key was minted. Limits are deliberately
  # empty — see the moduledoc.
  def tier_baseline(:owner), do: %{features: @owner_features, limits: %{}}

  # Paid tiers go here. Shape, for when there is something to sell:
  #
  #   def tier_baseline(:pro),
  #     do: %{features: [:container_execution_env], limits: %{max_concurrent_runs: 5}}
  #
  #   def tier_baseline(:business),
  #     do: %{
  #       features: [:container_execution_env, :sso],
  #       limits: %{max_concurrent_runs: 20}
  #     }

  # A tier this build does not know — from a key minted against a newer
  # release. Grants nothing of its own; the key's explicit features still
  # apply.
  def tier_baseline(_unknown), do: %{features: [], limits: %{}}

  @doc """
  The resolved grant for this instance.

  Falls back to the community grant when `load/0` has not run, so reads
  are safe from anywhere including tests that never boot the app.
  """
  @spec entitlements() :: Entitlements.t()
  def entitlements, do: :persistent_term.get(@cache_key, Entitlements.community())

  @doc """
  May this instance use `feature`?

  True for anything not listed in `@gated_features`, whether or not the
  instance holds a key.
  """
  @spec feature_enabled?(atom()) :: boolean()
  def feature_enabled?(feature) do
    policy_allows?(feature, @gated_features, entitlements().features)
  end

  @doc """
  A licensed numeric limit, or the caller's own default.

  The default belongs to the caller so an ungated call site keeps its
  existing behaviour with no coupling to this module's idea of what is
  reasonable.
  """
  @spec limit(atom(), term()) :: term()
  def limit(key, default), do: Map.get(entitlements().limits, key, default)

  @doc """
  The tier label, for display. Never use it to decide access — ask
  `feature_enabled?/1` instead, which honours per-key grants a label
  cannot express.
  """
  @spec tier() :: atom()
  def tier, do: entitlements().tier

  @doc """
  Resolves the configured key and caches the result. Called once from
  `CodeLead.Application.start/2`, before anything can read a limit.

  Never raises: every failure resolves to the community grant.
  """
  @spec load() :: Entitlements.t()
  def load do
    :code_lead
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:key)
    |> resolve_key()
    |> put_entitlements()
  end

  @doc false
  # The policy, with its inputs passed in so it can be exercised against a
  # populated gated set without touching the shipped one. Deliberately not
  # readable from config: a runtime switch that weakened this would be a
  # bypass, not a feature.
  @spec policy_allows?(atom(), MapSet.t(atom()), [atom()]) :: boolean()
  def policy_allows?(feature, gated_features, granted_features) do
    not MapSet.member?(gated_features, feature) or feature in granted_features
  end

  @doc false
  # Tier baseline ∪ the key's explicit grants. Features union; limits
  # merge with the key winning, so a bespoke deal can raise a cap its tier
  # sets lower.
  @spec merge_grant(atom(), [atom()], %{optional(atom()) => term()}) :: grant()
  def merge_grant(tier, explicit_features, explicit_limits) do
    baseline = tier_baseline(tier)

    %{
      features: Enum.uniq(baseline.features ++ explicit_features),
      limits: Map.merge(baseline.limits, explicit_limits)
    }
  end

  @doc false
  @spec put_entitlements(Entitlements.t()) :: Entitlements.t()
  def put_entitlements(%Entitlements{} = entitlements) do
    :persistent_term.put(@cache_key, entitlements)
    entitlements
  end

  @spec resolve_key(String.t() | nil) :: Entitlements.t()
  defp resolve_key(nil), do: Entitlements.community()

  defp resolve_key(key) do
    case Source.SignedKey.resolve(key) do
      {:ok, %Entitlements{tier: tier, org: org} = entitlements} ->
        Logger.info("License: #{tier}#{if org, do: " (#{org})"}")
        entitlements

      {:error, reason} ->
        Logger.warning("License key rejected (#{reason}); running community tier")
        Entitlements.community()
    end
  end
end
