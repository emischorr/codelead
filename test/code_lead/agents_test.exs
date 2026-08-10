defmodule CodeLead.AgentsTest do
  use CodeLead.DataCase, async: true

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures

  alias CodeLead.Agents

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
