defmodule CodeLead.Accounts.OrgEnv do
  @moduledoc """
  One key/value pair of the organization-wide env store, merged into every
  project's env vars (a project-level entry with the same key, matched
  case-insensitively, wins) — never logged and never written to task steps.
  Secret entries (the default) are encrypted at rest by the context before
  this schema ever sees them; plain entries are stored and readable as-is.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "org_envs" do
    field :key, :string
    field :value, :binary, redact: true
    field :secret, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for an env entry. `value` arrives pre-encrypted (or plain) —
  the context decides based on `secret`, not this changeset.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(org_env, attrs) do
    org_env
    |> cast(attrs, [:key, :value, :secret])
    |> validate_required([:key, :value])
    |> validate_format(:key, ~r/^[A-Za-z_][A-Za-z0-9_]*$/,
      message: "must be a valid environment variable name"
    )
    |> unique_constraint(:key, name: :org_envs_key_index)
  end
end
