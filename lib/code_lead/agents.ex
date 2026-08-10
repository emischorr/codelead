defmodule CodeLead.Agents do
  @moduledoc """
  Providers (model backends with encrypted credentials), agent
  personas, and per-project default reviewer sets.

  Selection rules (product spec §5): only agents matching a task's work
  type are selectable, executors need the `:execute` role, reviewers the
  `:review` role. Org-scoped agents are selectable everywhere,
  project-scoped ones only in their project.
  """

  import Ecto.Query

  alias CodeLead.Agents.Agent
  alias CodeLead.Agents.ProjectDefaultReviewer
  alias CodeLead.Agents.Provider
  alias CodeLead.Repo

  ## Providers

  @spec create_provider(map()) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def create_provider(attrs) do
    %Provider{}
    |> Provider.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_provider(Provider.t(), map()) ::
          {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def update_provider(provider, attrs) do
    provider
    |> Provider.changeset(attrs)
    |> Repo.update()
  end

  @spec list_providers() :: [Provider.t()]
  def list_providers do
    Repo.all(from p in Provider, order_by: p.name)
  end

  @spec get_provider!(pos_integer()) :: Provider.t()
  def get_provider!(id), do: Repo.get!(Provider, id)

  @spec get_provider_by_name(String.t()) :: Provider.t() | nil
  def get_provider_by_name(name), do: Repo.get_by(Provider, name: name)

  ## Agents

  @doc """
  Creates an agent. Pass `project_id` only for project-scoped agents.
  """
  @spec create_agent(map()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def create_agent(attrs) do
    project_id = attrs[:project_id] || attrs["project_id"]

    %Agent{project_id: project_id}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_agent(Agent.t(), map()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def update_agent(agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  @spec get_agent!(pos_integer()) :: Agent.t()
  def get_agent!(id), do: Repo.get!(Agent, id)

  @doc """
  All agents visible to a project: org-scoped plus the project's own.
  """
  @spec list_agents(pos_integer()) :: [Agent.t()]
  def list_agents(project_id) do
    Repo.all(visible_to_project(Agent, project_id))
  end

  @doc """
  Agents selectable as executor for a task of the given work type.
  """
  @spec eligible_executors(atom(), pos_integer()) :: [Agent.t()]
  def eligible_executors(work_type, project_id) do
    Repo.all(eligible(work_type, project_id, :execute))
  end

  @doc """
  Agents selectable as reviewer for a task of the given work type.
  """
  @spec eligible_reviewers(atom(), pos_integer()) :: [Agent.t()]
  def eligible_reviewers(work_type, project_id) do
    Repo.all(eligible(work_type, project_id, :review))
  end

  @doc """
  Checks a single agent against the selection rules for a slot
  (`:execute` or `:review`).
  """
  @spec eligible?(Agent.t(), atom(), pos_integer(), atom()) :: boolean()
  def eligible?(%Agent{} = agent, work_type, project_id, role) do
    agent.work_type == work_type and role in agent.roles and
      (agent.scope == :org or agent.project_id == project_id)
  end

  ## Default reviewers

  @doc """
  Replaces the project's default reviewer set for a work type. Every
  agent must be an eligible reviewer for that work type.
  """
  @spec set_default_reviewers(pos_integer(), atom(), [pos_integer()]) ::
          :ok | {:error, {:ineligible, [pos_integer()]}}
  def set_default_reviewers(project_id, work_type, agent_ids) do
    eligible_ids = MapSet.new(eligible(work_type, project_id, :review) |> Repo.all(), & &1.id)
    ineligible = Enum.reject(agent_ids, &MapSet.member?(eligible_ids, &1))

    if ineligible == [] do
      replace_default_reviewers(project_id, work_type, agent_ids)
      :ok
    else
      {:error, {:ineligible, ineligible}}
    end
  end

  @doc """
  The project's default reviewer agents for a work type.
  """
  @spec default_reviewers(pos_integer(), atom()) :: [Agent.t()]
  def default_reviewers(project_id, work_type) do
    Repo.all(
      from a in Agent,
        join: d in ProjectDefaultReviewer,
        on: d.agent_id == a.id,
        where: d.project_id == ^project_id and d.work_type == ^work_type,
        order_by: a.name
    )
  end

  defp replace_default_reviewers(project_id, work_type, agent_ids) do
    now = DateTime.utc_now(:second)

    entries =
      Enum.map(agent_ids, fn agent_id ->
        %{
          project_id: project_id,
          work_type: work_type,
          agent_id: agent_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.transaction(fn ->
      Repo.delete_all(
        from d in ProjectDefaultReviewer,
          where: d.project_id == ^project_id and d.work_type == ^work_type
      )

      Repo.insert_all(ProjectDefaultReviewer, entries)
    end)
  end

  defp eligible(work_type, project_id, role) do
    role_string = Atom.to_string(role)

    from a in visible_to_project(Agent, project_id),
      where: a.work_type == ^work_type,
      where: fragment("? = ANY(?)", ^role_string, a.roles)
  end

  defp visible_to_project(queryable, project_id) do
    from a in queryable,
      where: a.scope == :org or a.project_id == ^project_id,
      order_by: a.name
  end
end
