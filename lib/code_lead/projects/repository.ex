defmodule CodeLead.Projects.Repository do
  @moduledoc """
  A git repository linked to a project by URL. `base_clone_path` is
  filled in once the managed base clone exists on the workspace volume.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "repositories" do
    field :project_id, :id
    field :name, :string
    field :git_url, :string
    field :default_branch, :string, default: "main"
    field :base_clone_path, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for linking or updating a repository. `project_id` is set
  programmatically by the context, never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [:name, :git_url, :default_branch, :base_clone_path])
    |> validate_required([:name, :git_url, :default_branch])
    |> unique_constraint([:project_id, :name])
  end
end
