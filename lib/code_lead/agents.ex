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
  alias CodeLead.Tasks.Task
  alias CodeLead.Tasks.TaskReviewer

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

  @doc """
  The `config` key under which a provider kind keeps its credential.
  """
  @spec credential_key(atom() | String.t()) :: String.t()
  def credential_key(kind) when kind in [:ollama, "ollama"], do: "endpoint"

  def credential_key(kind) when kind in [:anthropic_subscription, "anthropic_subscription"],
    do: "oauth_token"

  def credential_key(_kind), do: "api_key"

  @doc """
  Creates or updates a provider from a form. The credential is merged into the
  stored config rather than replacing it, so a blank one keeps the stored
  secret — the form never round-trips a credential to the browser.

  A credential is required on create, and again when the kind changes, because
  each kind reads a different config key and `provider_env/1` would otherwise
  silently yield nothing.
  """
  @spec save_provider(Provider.t(), %{
          name: String.t(),
          kind: String.t(),
          credential: String.t() | nil
        }) :: {:ok, Provider.t()} | {:error, Ecto.Changeset.t()}
  def save_provider(%Provider{} = provider, %{name: name, kind: kind, credential: credential}) do
    credential = credential |> to_string() |> String.trim()
    kind_changed? = not is_nil(provider.id) and to_string(kind) != to_string(provider.kind)
    stored = provider.config || %{}

    config =
      if credential == "", do: stored, else: Map.put(stored, credential_key(kind), credential)

    provider
    |> Provider.changeset(%{name: name, kind: kind, config: config})
    |> require_credential(credential == "", is_nil(provider.id), kind_changed?)
    |> Repo.insert_or_update()
  end

  @doc """
  Names of the agents bound to a provider. A non-empty list blocks deletion.
  """
  @spec provider_usage(pos_integer()) :: [String.t()]
  def provider_usage(provider_id) do
    Repo.all(
      from a in Agent, where: a.provider_id == ^provider_id, order_by: a.name, select: a.name
    )
  end

  @doc """
  Deletes a provider unless an agent still points at it. Past `agent_runs`
  keep their cost figures — their `provider_id` nilifies.
  """
  @spec delete_provider(Provider.t()) :: {:ok, Provider.t()} | {:error, {:in_use, [String.t()]}}
  def delete_provider(%Provider{id: id} = provider) do
    case provider_usage(id) do
      [] -> Repo.delete(provider)
      names -> {:error, {:in_use, names}}
    end
  end

  defp require_credential(changeset, false, _new?, _kind_changed?), do: changeset

  defp require_credential(changeset, true, true, _kind_changed?),
    do: Ecto.Changeset.add_error(changeset, :config, "can't be blank")

  defp require_credential(changeset, true, false, true),
    do: Ecto.Changeset.add_error(changeset, :config, "is required when the backend changes")

  defp require_credential(changeset, true, false, false), do: changeset

  @doc """
  Environment variables an ACP harness subprocess needs to authenticate
  against the provider. Never log the result.
  """
  @spec provider_env(Provider.t()) :: [{String.t(), String.t()}]
  def provider_env(%Provider{kind: :anthropic_api, config: config}) do
    reject_missing([{"ANTHROPIC_API_KEY", config["api_key"]}])
  end

  def provider_env(%Provider{kind: :anthropic_subscription, config: config}) do
    reject_missing([{"CLAUDE_CODE_OAUTH_TOKEN", config["oauth_token"]}])
  end

  def provider_env(%Provider{}), do: []

  @doc """
  How a provider's reported cost should be read. Subscription runs are
  billed by seat, so their dollar figure is an API-equivalent estimate;
  a locally hosted model costs nothing. An unknown provider (the run's
  provider row was deleted) is treated as exact — the recorded number
  is all we have.

  Accepts a list for work spanning several providers, where an estimate
  anywhere makes the whole figure an estimate and only an all-local set
  is free.
  """
  @spec billing_mode(atom() | String.t() | nil | [atom() | String.t()]) ::
          :exact | :estimated | :free
  def billing_mode(kinds) when is_list(kinds) do
    modes = Enum.map(kinds, &billing_mode/1)

    cond do
      modes == [] -> :exact
      Enum.all?(modes, &(&1 == :free)) -> :free
      :estimated in modes -> :estimated
      true -> :exact
    end
  end

  def billing_mode(kind) when kind in [:anthropic_subscription, "anthropic_subscription"],
    do: :estimated

  def billing_mode(kind) when kind in [:ollama, "ollama"], do: :free
  def billing_mode(_kind), do: :exact

  defp reject_missing(pairs) do
    Enum.reject(pairs, fn {_key, value} -> value in [nil, ""] end)
  end

  ## Agents

  @doc """
  Creates an agent. `project_id` binds it to one project; a blank value
  keeps it org-wide (see `Agent.changeset/2`).
  """
  @spec create_agent(map()) :: {:ok, Agent.t()} | {:error, Ecto.Changeset.t()}
  def create_agent(attrs) do
    %Agent{}
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

  @spec change_agent(Agent.t(), map()) :: Ecto.Changeset.t()
  def change_agent(%Agent{} = agent, attrs \\ %{}), do: Agent.changeset(agent, attrs)

  @doc """
  Every agent, org- and project-scoped alike — the pool managed from
  Settings > Agents.
  """
  @spec list_all_agents() :: [Agent.t()]
  def list_all_agents do
    Repo.all(from a in Agent, order_by: a.name)
  end

  @doc """
  A project's own agents — bound to it specifically, not the shared org
  pool. Shown on the project's settings page.
  """
  @spec list_project_agents(pos_integer()) :: [Agent.t()]
  def list_project_agents(project_id) do
    Repo.all(
      from a in Agent,
        where: a.scope == :project and a.project_id == ^project_id,
        order_by: a.name
    )
  end

  @doc """
  Where an agent is still referenced. All-zero means it can be deleted.
  """
  @spec agent_usage(pos_integer()) :: %{
          tasks: non_neg_integer(),
          reviewer_slots: non_neg_integer(),
          default_reviewer_slots: non_neg_integer()
        }
  def agent_usage(agent_id) do
    %{
      tasks: Repo.aggregate(from(t in Task, where: t.agent_id == ^agent_id), :count),
      reviewer_slots:
        Repo.aggregate(from(r in TaskReviewer, where: r.agent_id == ^agent_id), :count),
      default_reviewer_slots:
        Repo.aggregate(from(d in ProjectDefaultReviewer, where: d.agent_id == ^agent_id), :count)
    }
  end

  @doc """
  Deletes an agent unless a task, a reviewer slot, or a default reviewer set
  still references it. The guard is load-bearing: those foreign keys nilify or
  cascade, so an unguarded delete would quietly strip executors and reviewers
  off existing tasks instead of failing.
  """
  @spec delete_agent(Agent.t()) :: {:ok, Agent.t()} | {:error, {:in_use, map()}}
  def delete_agent(%Agent{id: id} = agent) do
    usage = agent_usage(id)

    if usage.tasks == 0 and usage.reviewer_slots == 0 and usage.default_reviewer_slots == 0 do
      Repo.delete(agent)
    else
      {:error, {:in_use, usage}}
    end
  end

  @doc """
  Whether the instance has any agent at all. Used by the setup wizard.
  """
  @spec any_agents?() :: boolean()
  def any_agents?, do: Repo.exists?(Agent)

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
  Agents selectable as planning assistant for a task of the given work
  type. The driver decides the capability: `:llm_api` refines the spec
  from text, `:acp` surveys the repository read-only.
  """
  @spec eligible_planners(atom(), pos_integer()) :: [Agent.t()]
  def eligible_planners(work_type, project_id) do
    Repo.all(eligible(work_type, project_id, :plan))
  end

  @doc """
  Checks a single agent against the selection rules for a slot
  (`:execute`, `:review` or `:plan`).
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
