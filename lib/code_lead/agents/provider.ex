defmodule CodeLead.Agents.Provider do
  @moduledoc """
  An instance-level connection to a model backend. `config` carries
  tokens/keys/endpoint and is encrypted at rest.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds [:anthropic_subscription, :anthropic_api, :openai, :ollama]

  schema "providers" do
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :config, CodeLead.Encrypted.Map, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a provider.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:name, :kind, :config])
    |> validate_required([:name, :kind, :config])
    |> unique_constraint(:name)
  end
end
