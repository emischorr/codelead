defmodule CodeLeadWeb.SettingsLive.AgentsTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Agents

  setup :register_and_log_in_user

  describe "list" do
    test "shows org agents only", %{conn: conn} do
      project = project_fixture()
      org_agent = agent_fixture()
      project_agent = agent_fixture(%{scope: :project, project_id: project.id})

      {:ok, view, _html} = live(conn, ~p"/settings/agents")

      assert has_element?(view, "#agent-row-#{org_agent.id}")
      refute has_element?(view, "#agent-row-#{project_agent.id}")
    end

    test "routes to the provider page when none is connected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/agents")

      assert render(view) =~ "Connect a provider first"
      refute has_element?(view, "#new-agent")
    end
  end

  describe "create" do
    setup do
      %{provider: provider_fixture()}
    end

    test "the roles select becomes an atom list", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/agents/new")

      view
      |> form("#agent-form",
        agent: %{
          name: "Judy",
          work_type: "code",
          roles: "execute,review",
          driver: "acp",
          harness: "claude_code",
          provider_id: provider.id,
          model_variant: "claude-sonnet-5"
        }
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/agents")

      assert [agent] = Agents.list_org_agents()
      assert agent.roles == [:execute, :review]
      assert agent.scope == :org
      assert agent.harness == :claude_code
    end

    test "an llm_api agent is saved without a harness", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/agents/new")

      # the harness select still carries a value from the acp default
      view
      |> form("#agent-form",
        agent: %{
          name: "Reviewer",
          work_type: "code",
          roles: "review",
          driver: "llm_api",
          harness: "claude_code",
          provider_id: provider.id
        }
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/agents")

      assert [agent] = Agents.list_org_agents()
      assert agent.driver == :llm_api
      assert agent.roles == [:review]
      refute agent.harness
    end
  end

  describe "edit" do
    test "renames an agent", %{conn: conn} do
      agent = agent_fixture(%{name: "Old"})

      {:ok, view, _html} = live(conn, ~p"/settings/agents/#{agent.id}/edit")

      view
      |> form("#agent-form",
        agent: %{
          name: "New",
          work_type: "code",
          roles: "execute",
          driver: "llm_api",
          provider_id: agent.provider_id
        }
      )
      |> render_submit()

      assert_patch(view, ~p"/settings/agents")
      assert Agents.get_agent!(agent.id).name == "New"
    end
  end

  describe "delete" do
    test "is blocked while a task uses the agent", %{conn: conn} do
      project = project_fixture()
      agent = agent_fixture(%{roles: [:execute], work_type: :code})
      task_fixture(project.id, %{agent_id: agent.id})

      {:ok, view, _html} = live(conn, ~p"/settings/agents")

      assert has_element?(view, "#delete-agent-#{agent.id}[disabled]")
    end

    test "removes an unreferenced agent", %{conn: conn} do
      agent = agent_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/agents")

      view |> element("#delete-agent-#{agent.id}") |> render_click()

      refute has_element?(view, "#agent-row-#{agent.id}")
    end
  end
end
