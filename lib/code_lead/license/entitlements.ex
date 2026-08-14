defmodule CodeLead.License.Entitlements do
  @moduledoc """
  The resolved license grant for this instance.

  Instance-scoped, like the singleton `organization` — one deployment is
  one org, so entitlements govern the whole instance rather than a user
  or a project.

  `features` and `limits` are already merged (tier baseline ∪ the key's
  explicit grants); nothing downstream re-derives them. `tier` and `org`
  are metadata for display and billing, never consulted by policy —
  `CodeLead.License.feature_enabled?/1` reads `features`, not the label.
  """

  @enforce_keys [:tier]
  defstruct tier: :community, org: nil, features: [], limits: %{}, expires_at: nil

  @type t :: %__MODULE__{
          tier: atom(),
          org: String.t() | nil,
          features: [atom()],
          limits: %{optional(atom()) => term()},
          expires_at: String.t() | nil
        }

  @doc """
  The zero grant — what every instance runs on until a key says otherwise.

  Also what any failure degrades to; see `CodeLead.License.load/0`.
  """
  @spec community() :: t()
  def community, do: %__MODULE__{tier: :community, features: [], limits: %{}}
end
