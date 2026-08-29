defmodule CodeLead.Projects do
  @moduledoc """
  Projects, their linked repositories, and the project env store. Env
  entries are encrypted at rest by default; an entry can opt out to stay
  plain and editable.

  `projects.settings` is a free-form jsonb column; the keys this module
  gives meaning to are `"finalize"`, holding the project's Done
  defaults, and `"pr_template"`, holding the PR/MR description
  template. Both are read back through dedicated getters and written
  through dedicated setters rather than through the changeset, so a
  form editing them cannot clobber unrelated keys.
  """

  import Ecto.Query

  require Logger

  alias CodeLead.Accounts
  alias CodeLead.Git
  alias CodeLead.Projects.Project
  alias CodeLead.Projects.ProjectEnv
  alias CodeLead.Projects.Repository
  alias CodeLead.Repo
  alias CodeLead.Tasks.Task
  alias CodeLead.Vault
  alias CodeLead.Workspace

  @default_commit_path "artifacts"

  @default_pr_template """
  {{description}}

  ---
  Created by CodeLead for task \#{{task_id}}.
  """

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
  Links a git repository to a project. The first repository linked to a
  project becomes its default automatically; later ones are not, until
  `set_default_repository/1` moves it.
  """
  @spec link_repository(pos_integer(), map()) ::
          {:ok, Repository.t()} | {:error, Ecto.Changeset.t()}
  def link_repository(project_id, attrs) do
    %Repository{project_id: project_id}
    |> Repository.changeset(attrs)
    |> Ecto.Changeset.put_change(:is_default, first_repository?(project_id))
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

  @doc """
  Where the repository's managed base clone lives. The persisted path is
  a cache keyed on a workspace root that can move between boots; one
  recorded outside the current root is never trusted — it may point into
  a container's ephemeral layer — and the canonical location is used
  instead. Provisioning re-persists it on the next clone.
  """
  @spec base_clone_path(Repository.t()) :: String.t()
  def base_clone_path(%Repository{base_clone_path: nil} = repository) do
    Workspace.base_clone_path(repository.name, repository.id)
  end

  def base_clone_path(%Repository{base_clone_path: path} = repository) do
    if Workspace.under_root?(path) do
      path
    else
      recomputed = Workspace.base_clone_path(repository.name, repository.id)

      Logger.error(
        "repository #{repository.id}: recorded base clone at #{path} lies outside the " <>
          "workspace root — using #{recomputed} instead"
      )

      recomputed
    end
  end

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
  The project's default repository — what a new `:repo`-target task
  prefills — or nil when none is linked. Falls back to the first linked
  repository by insertion order if, somehow, none is marked default, so
  callers never see `nil` while repositories exist.
  """
  @spec default_repository(pos_integer()) :: Repository.t() | nil
  def default_repository(project_id) do
    Repo.one(
      from r in Repository,
        where: r.project_id == ^project_id,
        order_by: [desc: r.is_default, asc: r.id],
        limit: 1
    )
  end

  @doc """
  Marks a repository as its project's default, atomically clearing the
  flag off every other repository in the project — exactly one
  repository can be default, enforced by a partial unique index.
  """
  @spec set_default_repository(Repository.t()) ::
          {:ok, Repository.t()} | {:error, Ecto.Changeset.t()}
  def set_default_repository(%Repository{id: id, project_id: project_id}) do
    Repo.transact(fn ->
      Repo.update_all(
        from(r in Repository, where: r.project_id == ^project_id and r.id != ^id),
        set: [is_default: false]
      )

      Repository
      |> Repo.get!(id)
      |> Ecto.Changeset.change(is_default: true)
      |> Repo.update()
    end)
  end

  @doc """
  Upserts one env store entry. `secret` (default `true`) controls whether
  `value` is encrypted at rest; plain entries are stored and readable as-is.
  """
  @spec put_env(pos_integer(), String.t(), String.t(), boolean()) ::
          {:ok, ProjectEnv.t()} | {:error, Ecto.Changeset.t()}
  def put_env(project_id, key, value, secret \\ true) do
    stored_value = if secret, do: Vault.encrypt!(value), else: value

    %ProjectEnv{project_id: project_id}
    |> ProjectEnv.changeset(%{key: key, value: stored_value, secret: secret})
    |> Repo.insert(
      on_conflict: {:replace, [:value, :secret, :updated_at]},
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
  Env store entries for the settings UI. Secret entries come back with
  `value: nil` — a stored secret is never decrypted just to render a list;
  plain entries carry their real value since they were never encrypted.
  """
  @spec list_env_keys(pos_integer()) :: [
          %{key: String.t(), updated_at: DateTime.t(), secret: boolean(), value: String.t() | nil}
        ]
  def list_env_keys(project_id) do
    Repo.all(from e in ProjectEnv, where: e.project_id == ^project_id, order_by: e.key)
    |> Enum.map(fn %ProjectEnv{key: key, updated_at: updated_at, secret: secret, value: value} ->
      %{key: key, updated_at: updated_at, secret: secret, value: if(secret, do: nil, else: value)}
    end)
  end

  @doc """
  Decrypted env entries for executor injection. Never log the result.
  """
  @spec env_vars(pos_integer()) :: [{String.t(), String.t()}]
  def env_vars(project_id) do
    Repo.all(from e in ProjectEnv, where: e.project_id == ^project_id, order_by: e.key)
    |> Enum.map(fn %ProjectEnv{key: key, value: value, secret: secret} ->
      {key, if(secret, do: Vault.decrypt!(value), else: value)}
    end)
  end

  @doc """
  One decrypted env value, or nil. Never log the result.
  """
  @spec env_var(pos_integer(), String.t()) :: String.t() | nil
  def env_var(project_id, key) do
    case Repo.one(
           from e in ProjectEnv,
             where: e.project_id == ^project_id and e.key == ^key,
             select: {e.value, e.secret}
         ) do
      nil -> nil
      {value, true} -> Vault.decrypt!(value)
      {value, false} -> value
    end
  end

  @doc """
  The forge access token for a project — used both for git transport and
  for the PR/MR API call. Never log the result.
  """
  @spec forge_token(pos_integer(), :github | :gitlab) :: String.t() | nil
  def forge_token(project_id, kind) do
    env_var(project_id, Git.token_var(kind))
  end

  @doc """
  The project's Done defaults. A mode a target cannot use — or anything
  else the column happens to hold — comes back as `nil`, so a hand-edited
  or stale setting degrades to the built-in default instead of reaching
  the finalizer.
  """
  @spec finalize_defaults(pos_integer()) :: %{
          repo: Task.finalize_mode() | nil,
          folder: Task.finalize_mode() | nil,
          commit_path: String.t()
        }
  def finalize_defaults(project_id) do
    settings = Repo.one(from p in Project, where: p.id == ^project_id, select: p.settings) || %{}
    finalize = Map.get(settings, "finalize", %{})

    %{
      repo: stored_mode(finalize, "repo", :repo),
      folder: stored_mode(finalize, "folder", :folder),
      commit_path: stored_commit_path(finalize)
    }
  end

  @doc """
  Merges Done defaults into `settings`, leaving every other key alone.
  Blank values are dropped rather than stored, so clearing a select in
  the UI returns that target to the built-in default.
  """
  @spec put_finalize_defaults(Project.t(), map()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def put_finalize_defaults(%Project{settings: settings} = project, attrs) do
    finalize =
      %{
        "repo" => attrs["repo"],
        "folder" => attrs["folder"],
        "commit_path" => attrs["commit_path"]
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    project
    |> Ecto.Changeset.change(settings: Map.put(settings || %{}, "finalize", finalize))
    |> Repo.update()
  end

  @doc """
  Where a `:commit_to_path` finalize lands its artifact when the project
  has not said otherwise.
  """
  @spec default_commit_path() :: String.t()
  def default_commit_path, do: @default_commit_path

  @doc """
  The project's PR/MR description template, or the built-in default
  when none is set. `CodeLead.Finalizer` substitutes its placeholders
  (`{{title}}`, `{{description}}`, `{{task_id}}`, `{{branch}}`) when it
  opens a pull request.
  """
  @spec pr_template(pos_integer()) :: String.t()
  def pr_template(project_id) do
    settings = Repo.one(from p in Project, where: p.id == ^project_id, select: p.settings) || %{}

    case Map.get(settings, "pr_template") do
      template when is_binary(template) ->
        case String.trim(template) do
          "" -> @default_pr_template
          _non_blank -> template
        end

      _absent ->
        @default_pr_template
    end
  end

  @doc """
  Sets the project's PR/MR description template, leaving every other
  settings key alone. A blank value clears it back to the built-in
  default.
  """
  @spec put_pr_template(Project.t(), String.t()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def put_pr_template(%Project{settings: settings} = project, template) do
    settings =
      case String.trim(template || "") do
        "" -> Map.delete(settings || %{}, "pr_template")
        trimmed -> Map.put(settings || %{}, "pr_template", trimmed)
      end

    project
    |> Ecto.Changeset.change(settings: settings)
    |> Repo.update()
  end

  @doc """
  The built-in PR/MR description template, used to prefill the settings
  form when a project has not overridden it.
  """
  @spec default_pr_template() :: String.t()
  def default_pr_template, do: @default_pr_template

  # jsonb round-trips as string keys, and the value is operator-editable
  # data rather than application input — so it is matched against the
  # known atoms rather than converted into one.
  defp stored_mode(finalize, key, target) do
    stored = Map.get(finalize, key)
    Enum.find(Task.finalize_modes(target), &(Atom.to_string(&1) == stored))
  end

  defp stored_commit_path(finalize) do
    case Map.get(finalize, "commit_path") do
      path when is_binary(path) ->
        case String.trim(path) do
          "" -> @default_commit_path
          trimmed -> trimmed
        end

      _absent ->
        @default_commit_path
    end
  end

  defp maybe_link_repository(_project, nil), do: {:ok, nil}

  defp maybe_link_repository(project, attrs) do
    project.id |> link_repository(attrs) |> tag_error(:repository)
  end

  defp tag_error({:error, changeset}, tag), do: {:error, {tag, changeset}}
  defp tag_error(result, _tag), do: result

  defp first_repository?(project_id) do
    not Repo.exists?(from r in Repository, where: r.project_id == ^project_id)
  end
end
