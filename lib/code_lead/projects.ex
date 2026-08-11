defmodule CodeLead.Projects do
  @moduledoc """
  Projects, their linked repositories, and the encrypted project env
  store.
  """

  import Ecto.Query

  alias CodeLead.Accounts
  alias CodeLead.Git
  alias CodeLead.Projects.Project
  alias CodeLead.Projects.ProjectEnv
  alias CodeLead.Projects.Repository
  alias CodeLead.Repo
  alias CodeLead.Tasks.Task

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

  @spec change_project(Project.t(), map()) :: Ecto.Changeset.t()
  def change_project(%Project{} = project, attrs \\ %{}), do: Project.changeset(project, attrs)

  @doc """
  How many tasks still belong to a project. Non-zero blocks deletion.
  """
  @spec project_usage(pos_integer()) :: %{tasks: non_neg_integer()}
  def project_usage(project_id) do
    %{tasks: Repo.aggregate(from(t in Task, where: t.project_id == ^project_id), :count)}
  end

  @doc """
  Deletes a project along with its repositories, env store and project-scoped
  agents. Refuses while any task — archived ones included — still belongs to
  it, because `tasks.project_id` cascades and would take the whole history
  with it. The managed clone on disk is left alone.
  """
  @spec delete_project(Project.t()) :: {:ok, Project.t()} | {:error, {:has_tasks, pos_integer()}}
  def delete_project(%Project{id: id} = project) do
    case project_usage(id) do
      %{tasks: 0} -> Repo.delete(project)
      %{tasks: count} -> {:error, {:has_tasks, count}}
    end
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

  @doc """
  Creates a project and, when repository attrs are given, links its first
  repository in the same transaction — a rejected git URL must not leave a
  half-created project behind. Pass `nil` to create the project alone.
  """
  @spec create_project_with_repository(map(), map() | nil) ::
          {:ok, Project.t()} | {:error, :project | :repository, Ecto.Changeset.t()}
  def create_project_with_repository(project_attrs, repository_attrs) do
    Repo.transact(fn ->
      with {:ok, project} <- tag_error(create_project(project_attrs), :project),
           {:ok, _repository} <- maybe_link_repository(project, repository_attrs) do
        {:ok, project}
      end
    end)
    |> case do
      {:error, {tag, changeset}} -> {:error, tag, changeset}
      result -> result
    end
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

  @spec change_repository(Repository.t(), map()) :: Ecto.Changeset.t()
  def change_repository(%Repository{} = repository, attrs \\ %{}),
    do: Repository.changeset(repository, attrs)

  @doc """
  How many tasks target a repository. Non-zero blocks unlinking.
  """
  @spec repository_usage(pos_integer()) :: %{tasks: non_neg_integer()}
  def repository_usage(repository_id) do
    %{tasks: Repo.aggregate(from(t in Task, where: t.repository_id == ^repository_id), :count)}
  end

  @doc """
  Unlinks a repository unless a task still targets it — `tasks.repository_id`
  nilifies, which would strand a running task mid-flight.
  """
  @spec delete_repository(Repository.t()) ::
          {:ok, Repository.t()} | {:error, {:has_tasks, pos_integer()}}
  def delete_repository(%Repository{id: id} = repository) do
    case repository_usage(id) do
      %{tasks: 0} -> Repo.delete(repository)
      %{tasks: count} -> {:error, {:has_tasks, count}}
    end
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
  Env store keys without their values — what the settings UI lists. Selecting
  a bare map keeps Cloak from decrypting anything; `env_vars/1` would hand
  back every plaintext secret in the project.
  """
  @spec list_env_keys(pos_integer()) :: [%{key: String.t(), updated_at: DateTime.t()}]
  def list_env_keys(project_id) do
    Repo.all(
      from e in ProjectEnv,
        where: e.project_id == ^project_id,
        order_by: e.key,
        select: %{key: e.key, updated_at: e.updated_at}
    )
  end

  @doc """
  Decrypted env entries for executor injection. Never log the result.
  """
  @spec env_vars(pos_integer()) :: [{String.t(), String.t()}]
  def env_vars(project_id) do
    Repo.all(from e in ProjectEnv, where: e.project_id == ^project_id, order_by: e.key)
    |> Enum.map(fn %ProjectEnv{key: key, value: value} -> {key, value} end)
  end

  @doc """
  One decrypted env value, or nil. Never log the result.
  """
  @spec env_var(pos_integer(), String.t()) :: String.t() | nil
  def env_var(project_id, key) do
    Repo.one(
      from e in ProjectEnv,
        where: e.project_id == ^project_id and e.key == ^key,
        select: e.value
    )
  end

  @doc """
  The forge access token for a project — used both for git transport and
  for the PR/MR API call. Never log the result.
  """
  @spec forge_token(pos_integer(), :github | :gitlab) :: String.t() | nil
  def forge_token(project_id, kind) do
    env_var(project_id, Git.token_var(kind))
  end

  defp maybe_link_repository(_project, nil), do: {:ok, nil}

  defp maybe_link_repository(project, attrs) do
    project.id |> link_repository(attrs) |> tag_error(:repository)
  end

  defp tag_error({:error, changeset}, tag), do: {:error, {tag, changeset}}
  defp tag_error(result, _tag), do: result
end
