defmodule CodeLead.Accounts.User do
  @moduledoc """
  A person with a login. `hashed_password` stays nil until authentication
  flows arrive with the web UI iteration.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :hashed_password, :string, redact: true
    field :role, Ecto.Enum, values: [:admin, :member], default: :member
    field :locale, :string, default: "en"
    field :settings, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a user.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :role, :locale, :settings])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
  end
end
