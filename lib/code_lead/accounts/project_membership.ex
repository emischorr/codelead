defmodule CodeLead.Accounts.ProjectMembership do
  @moduledoc """
  A user's role on one project. Roles are ordered (`reporter < member <
  maintainer`); `CodeLead.Accounts.Policy` compares them through a rank map,
  so a future role slots in without touching the checks. Admins bypass
  membership entirely and have no rows.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @roles [:reporter, :member, :maintainer]

  @type t :: %__MODULE__{}
  @type role :: :reporter | :member | :maintainer

  schema "project_memberships" do
    field :role, Ecto.Enum, values: @roles

    belongs_to :project, CodeLead.Projects.Project
    belongs_to :user, CodeLead.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  The project roles, lowest to highest.
  """
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc """
  Changeset for creating or updating a membership. `project_id` and
  `user_id` are set programmatically and never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> unique_constraint([:project_id, :user_id])
  end
end
