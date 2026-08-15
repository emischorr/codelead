defmodule CodeLead.LicenseHelpers do
  @moduledoc """
  Installs an instance-wide license grant for tests.

  The suite runs as an `:owner` instance (see `test/test_helper.exs`) so
  that licensed paths — container execution today — are exercised by the
  ordinary tests rather than skipped. A test that asserts the *gate*
  installs `grant_community!/0` in its own `setup` and restores
  `grant_owner!/0` on exit.

  Both write `:persistent_term`, which is VM-global: a module calling
  `grant_community!/0` must be `async: false`.
  """

  alias CodeLead.License
  alias CodeLead.License.Entitlements

  @doc """
  Grants every gated feature, as a real `:owner` key would.
  """
  @spec grant_owner!() :: Entitlements.t()
  def grant_owner! do
    %{features: features, limits: limits} = License.tier_baseline(:owner)

    License.put_entitlements(%Entitlements{
      tier: :owner,
      org: "Test Instance",
      features: features,
      limits: limits
    })
  end

  @doc """
  Drops the instance back to the unlicensed grant.
  """
  @spec grant_community!() :: Entitlements.t()
  def grant_community!, do: License.put_entitlements(Entitlements.community())
end
