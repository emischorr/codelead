defmodule CodeLead.License.Source do
  @moduledoc """
  Behaviour for turning whatever an operator supplies into resolved
  `CodeLead.License.Entitlements`.

  MVP implementation: `SignedKey` — an offline Ed25519-signed token read
  from `LICENSE_KEY`. Offline verification is the deliberate choice: a
  self-hosted instance must not need to reach a vendor server to keep
  working, which rules out online activation. A later hosted offering
  would add a source that trades the token for a server-issued grant;
  the boot path and everything downstream stay as they are.

  Unlike `CodeLead.Executor` and `CodeLead.Scheduler`, this behaviour
  deliberately exposes **no `impl/0` resolver**. Those two are swapped
  through application config; a config-swappable license source would be
  a bypass — set it to a module that returns every feature and the seam
  is gone. `CodeLead.License.load/0` names its source directly.
  """

  alias CodeLead.License.Entitlements

  @typedoc """
  Why a supplied license did not resolve. Every one of these degrades to
  the community tier rather than failing the boot.
  """
  @type error ::
          :bad_signature
          | :expired
          | :malformed
          | :no_public_key

  @doc """
  Resolves supplied license material into a grant.

  Must never raise and must never reach the network.
  """
  @callback resolve(material :: term()) :: {:ok, Entitlements.t()} | {:error, error()}
end
