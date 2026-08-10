defmodule CodeLead.Projects do
  @moduledoc """
  Projects, their linked repositories, and the encrypted project env
  store.
  """

  import Ecto.Query

  alias CodeLead.Accounts
  alias CodeLead.Projects.Project
  alias CodeLead.Projects.ProjectEnv
  alias CodeLead.Projects.Repository
  alias CodeLead.Repo

  @doc """
  Creates a project under the organization singleton.
  """
  @spec create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs) do
    organization = Accounts.get_organization!()

    %Project{org_id: organization.id}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @spec list_projects() :: [Project.t()]
  def list_projects do
    Repo.all(from p in Project, order_by: p.name)
  end

  @spec get_project!(pos_integer()) :: Project.t()
  def get_project!(id), do: Repo.get!(Project, id)

  @spec update_project(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update_project(project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Links a git repository to a project.
  """
  @spec link_repository(pos_integer(), map()) ::
          {:ok, Repository.t()} | {:error, Ecto.Changeset.t()}
  def link_repository(project_id, attrs) do
    %Repository{project_id: project_id}
    |> Repository.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_repository!(pos_integer()) :: Repository.t()
  def get_repository!(id), do: Repo.get!(Repository, id)

  @spec list_repositories(pos_integer()) :: [Repository.t()]
  def list_repositories(project_id) do
    Repo.all(from r in Repository, where: r.project_id == ^project_id, order_by: r.name)
  end

  @spec update_repository(Repository.t(), map()) ::
          {:ok, Repository.t()} | {:error, Ecto.Changeset.t()}
  def update_repository(repository, attrs) do
    repository
    |> Repository.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns the first linked repository of a project — the default for new
  `:repo`-target tasks — or nil.
  """
  @spec default_repository(pos_integer()) :: Repository.t() | nil
  def default_repository(project_id) do
    Repo.one(
      from r in Repository,
        where: r.project_id == ^project_id,
        order_by: [asc: r.id],
        limit: 1
    )
  end

  @doc """
  Upserts one env store entry.
  """
  @spec put_env(pos_integer(), String.t(), String.t()) ::
          {:ok, ProjectEnv.t()} | {:error, Ecto.Changeset.t()}
  def put_env(project_id, key, value) do
    %ProjectEnv{project_id: project_id}
    |> ProjectEnv.changeset(%{key: key, value: value})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:project_id, :key],
      returning: true
    )
  end

  @spec delete_env(pos_integer(), String.t()) :: :ok
  def delete_env(project_id, key) do
    Repo.delete_all(from e in ProjectEnv, where: e.project_id == ^project_id and e.key == ^key)

    :ok
  end

  @doc """
  Decrypted env entries for executor injection. Never log the result.
  """
  @spec env_vars(pos_integer()) :: [{String.t(), String.t()}]
  def env_vars(project_id) do
    Repo.all(from e in ProjectEnv, where: e.project_id == ^project_id, order_by: e.key)
    |> Enum.map(fn %ProjectEnv{key: key, value: value} -> {key, value} end)
  end
end
