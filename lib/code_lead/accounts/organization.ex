defmodule CodeLead.Accounts.Organization do
  @moduledoc """
  The instance-wide organization singleton (one deployed instance = one
  organization). Uniqueness is enforced by a constant `singleton` column
  with a unique index.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "organizations" do
    field :name, :string
    field :settings, :map, default: %{}
    field :budget_limit_cents, :integer
    field :budget_limit_tokens, :integer
    field :singleton, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating the organization.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :settings, :budget_limit_cents, :budget_limit_tokens])
    |> validate_required([:name])
    |> validate_number(:budget_limit_cents, greater_than_or_equal_to: 0)
    |> validate_number(:budget_limit_tokens, greater_than_or_equal_to: 0)
    |> unique_constraint(:singleton)
  end
end
