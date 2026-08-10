defmodule CodeLead.Projects.Project do
  @moduledoc """
  A product workspace: links repositories and owns tasks, project-level
  agents, the env store, and budgets.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeLead.Projects.Repository

  @type t :: %__MODULE__{}

  schema "projects" do
    field :org_id, :id
    field :name, :string
    field :settings, :map, default: %{}
    field :budget_limit_cents, :integer
    field :budget_limit_tokens, :integer

    has_many :repositories, Repository

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a project. `org_id` is set
  programmatically by the context, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :settings, :budget_limit_cents, :budget_limit_tokens])
    |> validate_required([:name])
    |> validate_number(:budget_limit_cents, greater_than_or_equal_to: 0)
    |> validate_number(:budget_limit_tokens, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end
end
