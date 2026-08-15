defmodule CodeLead.LicenseTest do
  # Not async: the resolved grant lives in `:persistent_term`, which is
  # VM-global. A concurrent test reading `feature_enabled?/1` would see
  # whatever the cache tests below happen to have installed.
  use ExUnit.Case, async: false

  alias CodeLead.License
  alias CodeLead.License.Entitlements
  alias CodeLead.LicenseHelpers

  # The suite as a whole runs as `:owner` (test/test_helper.exs); these
  # tests install their own grant and must hand that back.
  setup do
    on_exit(&LicenseHelpers.grant_owner!/0)
    :ok
  end

  describe "the shipped policy" do
    setup do
      LicenseHelpers.grant_community!()
      :ok
    end

    test "leaves everything not named in the seam alone" do
      assert License.feature_enabled?(:cost_dashboard)
      assert License.feature_enabled?(:sso)
      assert License.feature_enabled?(:anything_at_all)
    end

    test "withholds container execution from an instance holding no license" do
      refute License.feature_enabled?(:container_execution_env)
    end

    test "limit/2 hands back the caller's own default" do
      assert License.limit(:max_concurrent_runs, 3) == 3
      assert License.limit(:seats, :unlimited) == :unlimited
    end

    test "an instance with no key is community" do
      assert License.tier() == :community
    end
  end

  describe "an owner instance" do
    setup do
      LicenseHelpers.grant_owner!()
      :ok
    end

    test "may use container execution" do
      assert License.feature_enabled?(:container_execution_env)
    end

    # Written against the live gated set rather than a literal list, so
    # gating the *next* feature does not need this test edited — which is
    # the whole promise of the :owner baseline.
    test "may use every gated feature there is" do
      %{features: granted} = License.tier_baseline(:owner)

      for feature <- granted do
        assert License.feature_enabled?(feature)
      end
    end
  end

  describe "policy_allows?/3" do
    setup do
      %{gated: MapSet.new([:cost_dashboard, :sso])}
    end

    test "an ungated feature is allowed however little is granted", %{gated: gated} do
      assert License.policy_allows?(:agent_marketplace, gated, [])
    end

    test "a gated feature needs a grant", %{gated: gated} do
      refute License.policy_allows?(:cost_dashboard, gated, [])
      refute License.policy_allows?(:cost_dashboard, gated, [:sso])
      assert License.policy_allows?(:cost_dashboard, gated, [:cost_dashboard])
    end

    test "gating one feature does not gate its neighbours", %{gated: gated} do
      granted = [:cost_dashboard]

      assert License.policy_allows?(:cost_dashboard, gated, granted)
      refute License.policy_allows?(:sso, gated, granted)
      assert License.policy_allows?(:anything_ungated, gated, granted)
    end

    test "an empty gated set allows everything" do
      refute License.policy_allows?(:sso, MapSet.new([:sso]), [])
      assert License.policy_allows?(:sso, MapSet.new(), [])
    end
  end

  describe "tier_baseline/1" do
    test "community grants nothing" do
      assert License.tier_baseline(:community) == %{features: [], limits: %{}}
    end

    test "a tier this build has no clause for grants nothing rather than raising" do
      assert License.tier_baseline(:platinum) == %{features: [], limits: %{}}
    end

    test "owner grants container execution" do
      assert %{features: features} = License.tier_baseline(:owner)

      assert :container_execution_env in features
    end

    test "owner grants no limits — a raised cap still needs an explicit one" do
      assert License.tier_baseline(:owner).limits == %{}
    end
  end

  describe "merge_grant/3" do
    test "a key with no extras gets exactly its tier baseline" do
      assert License.merge_grant(:community, [], %{}) == %{features: [], limits: %{}}
    end

    test "explicit features extend the baseline" do
      assert %{features: [:sso]} = License.merge_grant(:community, [:sso], %{})
    end

    test "explicit limits extend the baseline" do
      assert %{limits: %{seats: 50}} = License.merge_grant(:community, [], %{seats: 50})
    end

    test "features union rather than replace, without duplicating" do
      %{features: features} = License.merge_grant(:community, [:sso, :sso, :cost_dashboard], %{})

      assert Enum.sort(features) == [:cost_dashboard, :sso]
    end

    test "an unknown tier still honours the key's explicit grants" do
      assert %{features: [:sso], limits: %{seats: 5}} =
               License.merge_grant(:platinum, [:sso], %{seats: 5})
    end
  end

  describe "entitlements/0" do
    test "defaults to community when load/0 has not run" do
      :persistent_term.erase({License, :entitlements})

      assert %Entitlements{tier: :community, features: [], limits: %{}} = License.entitlements()
    end

    test "reads back what was cached" do
      License.put_entitlements(%Entitlements{
        tier: :business,
        org: "Sibling Corp",
        features: [:sso],
        limits: %{seats: 50}
      })

      assert License.tier() == :business
      assert License.entitlements().org == "Sibling Corp"
      assert License.limit(:seats, 1) == 50
    end

    test "a licensed limit overrides the caller's default, an unlicensed one does not" do
      License.put_entitlements(%Entitlements{tier: :pro, limits: %{max_concurrent_runs: 50}})

      assert License.limit(:max_concurrent_runs, 3) == 50
      assert License.limit(:seats, 3) == 3
    end
  end

  describe "load/0" do
    setup do
      previous = Application.get_env(:code_lead, License)
      on_exit(fn -> Application.put_env(:code_lead, License, previous) end)
      :ok
    end

    test "no configured key resolves to community" do
      Application.put_env(:code_lead, License, key: nil)

      assert %Entitlements{tier: :community} = License.load()
      assert License.tier() == :community
    end

    test "an unusable key fails open rather than failing the boot" do
      Application.put_env(:code_lead, License, key: "not-a-license-key")

      assert %Entitlements{tier: :community} = License.load()
    end

    test "a key signed by someone else fails open" do
      {_public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
      forged = CodeLead.License.Source.SignedKey.mint(%{"tier" => "business"}, private_key)

      Application.put_env(:code_lead, License, key: forged)

      assert %Entitlements{tier: :community} = License.load()
    end

    test "missing config entirely is the same as no key" do
      Application.delete_env(:code_lead, License)

      assert %Entitlements{tier: :community} = License.load()
    end
  end
end
