defmodule CodeLead.AgentsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Agents
  alias CodeLead.Agents.Provider
  alias CodeLead.Tasks

  describe "providers" do
    test "config is encrypted at rest and decrypts on read" do
      provider = provider_fixture(%{config: %{"api_key" => "sk-secret"}})

      %{rows: [[raw]]} =
        Repo.query!("SELECT config FROM providers WHERE id = $1", [provider.id])

      refute is_map(raw) and raw["api_key"]
      refute to_string(raw) =~ "sk-secret"

      assert Agents.get_provider!(provider.id).config == %{"api_key" => "sk-secret"}
    end
  end

  describe "save_provider/2" do
    # The regression that matters: `Provider.changeset/2` casts `config` as a
    # whole map, so a form write must merge rather than replace.
    test "a blank credential keeps the stored secret" do
      provider = provider_fixture(%{config: %{"api_key" => "sk-secret"}})

      assert {:ok, _saved} =
               Agents.save_provider(provider, %{
                 name: "Renamed",
                 kind: "anthropic_api",
                 credential: ""
               })

      reloaded = Agents.get_provider!(provider.id)
      assert reloaded.name == "Renamed"
      assert reloaded.config == %{"api_key" => "sk-secret"}
    end

    test "a new credential replaces the stored one" do
      provider = provider_fixture(%{config: %{"api_key" => "sk-old"}})

      assert {:ok, _saved} =
               Agents.save_provider(provider, %{
                 name: provider.name,
                 kind: "anthropic_api",
                 credential: "  sk-new  "
               })

      assert Agents.get_provider!(provider.id).config == %{"api_key" => "sk-new"}
    end

    test "creating without a credential is rejected" do
      assert {:error, changeset} =
               Agents.save_provider(%Provider{}, %{
                 name: "Anthropic",
                 kind: "anthropic_api",
                 credential: ""
               })

      assert %{config: _} = errors_on(changeset)
    end

    test "changing the kind requires a new credential" do
      provider = provider_fixture(%{kind: :anthropic_api, config: %{"api_key" => "sk-secret"}})

      assert {:error, changeset} =
               Agents.save_provider(provider, %{
                 name: provider.name,
                 kind: "anthropic_subscription",
                 credential: ""
               })

      assert %{config: _} = errors_on(changeset)
    end

    test "changing the kind with a credential writes it under the new key" do
      provider = provider_fixture(%{kind: :anthropic_api, config: %{"api_key" => "sk-secret"}})

      assert {:ok, _saved} =
               Agents.save_provider(provider, %{
                 name: provider.name,
                 kind: "anthropic_subscription",
                 credential: "oauth-abc"
               })

      config = Agents.get_provider!(provider.id).config
      assert config["oauth_token"] == "oauth-abc"
      assert config["api_key"] == "sk-secret"
    end

    test "an ollama credential lands under the endpoint key" do
      assert {:ok, provider} =
               Agents.save_provider(%Provider{}, %{
                 name: "Local",
                 kind: "ollama",
                 credential: "http://localhost:11434"
               })

      assert provider.config == %{"endpoint" => "http://localhost:11434"}
    end
  end

  describe "delete_provider/1" do
    test "refuses while an agent still uses it" do
      provider = provider_fixture()
      agent = agent_fixture(%{provider_id: provider.id})

      assert {:error, {:in_use, [name]}} = Agents.delete_provider(provider)
      assert name == agent.name

      {:ok, _agent} = Agents.delete_agent(agent)
      assert {:ok, _provider} = Agents.delete_provider(provider)
    end
  end

  describe "agent deletion" do
    test "list_org_agents/0 excludes project-scoped agents" do
      project = project_fixture()
      org_agent = agent_fixture()
      _project_agent = agent_fixture(%{scope: :project, project_id: project.id})

      assert Enum.map(Agents.list_org_agents(), & &1.id) == [org_agent.id]
    end

    test "an unreferenced agent deletes" do
      agent = agent_fixture()

      assert Agents.agent_usage(agent.id) ==
               %{tasks: 0, reviewer_slots: 0, default_reviewer_slots: 0}

      assert {:ok, _agent} = Agents.delete_agent(agent)
    end

    test "refuses while a task uses it as executor" do
      project = project_fixture()
      agent = agent_fixture(%{roles: [:execute], work_type: :code})
      task_fixture(project.id, %{agent_id: agent.id})

      assert {:error, {:in_use, %{tasks: 1}}} = Agents.delete_agent(agent)
    end

    test "refuses while a task lists it as reviewer" do
      project = project_fixture()
      reviewer = agent_fixture(%{roles: [:review], work_type: :code})
      task = task_fixture(project.id, %{work_type: :code})
      :ok = Tasks.set_reviewers(task, [reviewer.id])

      assert {:error, {:in_use, %{reviewer_slots: 1}}} = Agents.delete_agent(reviewer)
    end

    test "refuses while it is a project default reviewer" do
      project = project_fixture()
      reviewer = agent_fixture(%{roles: [:review], work_type: :code})
      :ok = Agents.set_default_reviewers(project.id, :code, [reviewer.id])

      assert {:error, {:in_use, %{default_reviewer_slots: 1}}} = Agents.delete_agent(reviewer)
    end
  end

  describe "agent validations" do
    test "acp driver requires a harness" do
      provider = provider_fixture()

      assert {:error, changeset} =
               Agents.create_agent(%{
                 name: "Coder",
                 scope: :org,
                 roles: [:execute],
                 work_type: :code,
                 driver: :acp,
                 provider_id: provider.id
               })

      assert %{harness: _} = errors_on(changeset)
    end

    test "llm_api driver must not carry a harness" do
      provider = provider_fixture()

      assert {:error, changeset} =
               Agents.create_agent(%{
                 name: "Reviewer",
                 scope: :org,
                 roles: [:review],
                 work_type: :code,
                 driver: :llm_api,
                 harness: :claude_code,
                 provider_id: provider.id
               })

      assert %{harness: _} = errors_on(changeset)
    end

    test "project scope requires project_id, org scope forbids it" do
      provider = provider_fixture()
      project = project_fixture()

      assert {:error, changeset} =
               Agents.create_agent(%{
                 name: "A",
                 scope: :project,
                 roles: [:execute],
                 work_type: :code,
                 driver: :llm_api,
                 provider_id: provider.id
               })

      assert %{project_id: _} = errors_on(changeset)

      assert {:error, changeset} =
               Agents.create_agent(%{
                 name: "A",
                 scope: :org,
                 project_id: project.id,
                 roles: [:execute],
                 work_type: :code,
                 driver: :llm_api,
                 provider_id: provider.id
               })

      assert %{project_id: _} = errors_on(changeset)
    end

    test "roles must not be empty" do
      provider = provider_fixture()

      assert {:error, changeset} =
               Agents.create_agent(%{
                 name: "A",
                 scope: :org,
                 roles: [],
                 work_type: :code,
                 driver: :llm_api,
                 provider_id: provider.id
               })

      assert %{roles: _} = errors_on(changeset)
    end
  end

  describe "eligibility" do
    test "filters by work type, role, and scope" do
      project = project_fixture()
      other_project = project_fixture()

      org_coder = agent_fixture(%{roles: [:execute, :review], work_type: :code})
      _content_agent = agent_fixture(%{roles: [:execute], work_type: :content})
      review_only = agent_fixture(%{roles: [:review], work_type: :code})

      project_coder =
        agent_fixture(%{
          scope: :project,
          project_id: project.id,
          roles: [:execute],
          work_type: :code
        })

      _foreign_coder =
        agent_fixture(%{
          scope: :project,
          project_id: other_project.id,
          roles: [:execute],
          work_type: :code
        })

      executor_ids = Agents.eligible_executors(:code, project.id) |> Enum.map(& &1.id)
      assert Enum.sort(executor_ids) == Enum.sort([org_coder.id, project_coder.id])

      reviewer_ids = Agents.eligible_reviewers(:code, project.id) |> Enum.map(& &1.id)
      assert Enum.sort(reviewer_ids) == Enum.sort([org_coder.id, review_only.id])

      assert Agents.eligible?(org_coder, :code, project.id, :execute)
      refute Agents.eligible?(review_only, :code, project.id, :execute)
      refute Agents.eligible?(org_coder, :content, project.id, :execute)
    end
  end

  describe "default reviewers" do
    test "set and read back per work type" do
      project = project_fixture()
      reviewer = agent_fixture(%{roles: [:review], work_type: :code})
      other = agent_fixture(%{roles: [:review], work_type: :code})

      assert :ok = Agents.set_default_reviewers(project.id, :code, [reviewer.id, other.id])

      ids = Agents.default_reviewers(project.id, :code) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([reviewer.id, other.id])

      # replaces, not appends
      assert :ok = Agents.set_default_reviewers(project.id, :code, [reviewer.id])
      assert [%{id: id}] = Agents.default_reviewers(project.id, :code)
      assert id == reviewer.id
    end

    test "rejects agents that are not eligible reviewers" do
      project = project_fixture()
      executor_only = agent_fixture(%{roles: [:execute], work_type: :code})
      wrong_type = agent_fixture(%{roles: [:review], work_type: :content})

      assert {:error, {:ineligible, ids}} =
               Agents.set_default_reviewers(project.id, :code, [
                 executor_only.id,
                 wrong_type.id
               ])

      assert Enum.sort(ids) == Enum.sort([executor_only.id, wrong_type.id])
    end
  end
end
