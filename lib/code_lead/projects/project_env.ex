defmodule CodeLead.Projects.ProjectEnv do
  @moduledoc """
  One key/value pair of a project's env store, injected as environment
  variables at executor spawn — never logged and never written to task
  steps. Secret entries (the default) are encrypted at rest by the
  context before this schema ever sees them; plain entries are stored
  and readable as-is.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "project_envs" do
    field :project_id, :id
    field :key, :string
    field :value, :binary, redact: true
    field :secret, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for an env entry. `project_id` is set programmatically by
  the context, never cast. `value` arrives pre-encrypted (or plain) —
  the context decides based on `secret`, not this changeset.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project_env, attrs) do
    project_env
    |> cast(attrs, [:key, :value, :secret])
    |> validate_required([:key, :value])
    |> validate_format(:key, ~r/^[A-Za-z_][A-Za-z0-9_]*$/,
      message: "must be a valid environment variable name"
    )
    |> unique_constraint([:project_id, :key])
  end
end
