defmodule CodeLead.Projects.Project do
  @moduledoc """
  A product workspace: links repositories and owns tasks, project-level
  agents, the env store, and budgets.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeLead.Projects.Repository

  @type t :: %__MODULE__{}
  @type color ::
          :blue | :indigo | :violet | :pink | :red | :cyan | :teal | :green | :lime | :yellow

  @colors [:blue, :indigo, :violet, :pink, :red, :cyan, :teal, :green, :lime, :yellow]

  schema "projects" do
    field :org_id, :id
    field :name, :string
    field :settings, :map, default: %{}
    field :budget_limit_cents, :integer
    field :budget_limit_tokens, :integer
    field :color, Ecto.Enum, values: @colors, default: :blue

    has_many :repositories, Repository

    timestamps(type: :utc_datetime)
  end

  @doc """
  The selectable identity colors, in the order the picker offers them.
  """
  @spec colors() :: [color()]
  def colors, do: @colors

  @doc """
  Changeset for creating or updating a project. `org_id` is set
  programmatically by the context, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :settings, :budget_limit_cents, :budget_limit_tokens, :color])
    |> validate_required([:name])
    |> validate_number(:budget_limit_cents, greater_than_or_equal_to: 0)
    |> validate_number(:budget_limit_tokens, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end
end
