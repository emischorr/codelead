defmodule CodeLeadWeb.RoleVisibilityTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AccountsFixtures
  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Accounts
  alias CodeLead.Accounts.Scope
  alias CodeLead.Tasks

  setup :register_and_log_in_user

  defp join(project, user, role) do
    membership_fixture(project, user, role)
    Scope.for_user(user)
  end

  describe "reporter on the board" do
    setup %{user: user} do
      project = project_fixture()
      scope = join(project, user, :reporter)
      %{project: project, scope: scope}
    end

    test "sees cards but no start or schedule controls", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      repository = repository_fixture(project.id)
      executor = agent_fixture(%{roles: [:execute], work_type: :code})

      {:ok, task} =
        Tasks.create_task(scope, project.id, %{
          title: "Startable",
          work_type: :code,
          target: :repo,
          repository_id: repository.id,
          agent_id: executor.id
        })

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert has_element?(view, "#task-card-#{task.id}")
      refute has_element?(view, "#task-card-#{task.id}-start")
      refute has_element?(view, "#task-card-#{task.id}-schedule")
      # Creating tasks stays open to reporters.
      assert has_element?(view, "#new-task-button")
    end
  end

  describe "reporter on the task page" do
    setup %{user: user} do
      project = project_fixture()
      scope = join(project, user, :reporter)
      %{project: project, scope: scope}
    end

    test "own planning task is editable but not operable", %{
      conn: conn,
      project: project,
      scope: scope
    } do
      {:ok, task} = Tasks.create_task(scope, project.id, %{title: "Mine", work_type: :code})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/tasks/#{task.id}")

      assert has_element?(view, "#toggle-edit")
      refute has_element?(view, "#action-start-run")
      refute has_element?(view, "#action-schedule-run")
      refute has_element?(view, "#executor-form")
      refute has_element?(view, "#reviewers-form")
    end

    test "someone else's task is fully read-only", %{conn: conn, project: project} do
      other = user_fixture()
      other_scope = join(project, other, :member)

      {:ok, task} =
        Tasks.create_task(other_scope, project.id, %{title: "Theirs", work_type: :code})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/tasks/#{task.id}")

      assert has_element?(view, "#description-card")
      refute has_element?(view, "#toggle-edit")
      refute has_element?(view, "#action-start-run")
      refute has_element?(view, "#planner-form")
      refute has_element?(view, "#target-form")
    end
  end

  describe "member on the task page" do
    test "gets the full set of controls", %{conn: conn, user: user} do
      project = project_fixture()
      scope = join(project, user, :member)
      {:ok, task} = Tasks.create_task(scope, project.id, %{title: "Work", work_type: :code})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/tasks/#{task.id}")

      assert has_element?(view, "#action-start-run")
      assert has_element?(view, "#toggle-edit")
      assert has_element?(view, "#executor-form")
    end
  end

  describe "maintainer on project settings" do
    setup %{user: user} do
      project = project_fixture()
      scope = join(project, user, :maintainer)
      %{project: project, scope: scope}
    end

    test "budget inputs are disabled with a hint", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/settings/projects/#{project.id}")

      assert has_element?(
               view,
               "#project-details-form input[name='project[budget_limit_cents]'][disabled]"
             )

      assert html =~ "Budget limits are set by an administrator."
    end

    test "manages members from the members section", %{conn: conn, project: project, user: user} do
      other = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/projects/#{project.id}")
      # Add
      view |> element("#add-member") |> render_click()

      view
      |> form("#member-form", member: %{user_id: other.id, role: "reporter"})
      |> render_submit()

      assert Accounts.membership_map(other.id) |> Map.fetch!(project.id) == :reporter

      # Change role
      [membership] =
        for m <- Accounts.list_project_members(project.id), m.user_id == other.id, do: m

      view
      |> element("#member-role-form-#{membership.id}")
      |> render_change(%{"membership_id" => membership.id, "role" => "member"})

      assert Accounts.membership_map(other.id) |> Map.fetch!(project.id) == :member

      # Remove
      view |> element("#remove-member-#{membership.id}") |> render_click()
      assert Accounts.membership_map(other.id) == %{}

      # The maintainer's own row is still there.
      assert Enum.map(Accounts.list_project_members(project.id), & &1.user_id) == [user.id]
    end
  end

  describe "admin on project settings" do
    @tag role: :admin
    test "budget inputs are editable", %{conn: conn} do
      project = project_fixture()
      {:ok, view, html} = live(conn, ~p"/settings/projects/#{project.id}")

      refute has_element?(
               view,
               "#project-details-form input[name='project[budget_limit_cents]'][disabled]"
             )

      refute html =~ "Budget limits are set by an administrator."
    end
  end

  describe "member dashboard" do
    test "shows only membership projects", %{conn: conn, user: user} do
      mine = project_fixture(%{name: "Mine Project"})
      _other = project_fixture(%{name: "Foreign Project"})
      join(mine, user, :member)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Mine Project"
      refute html =~ "Foreign Project"
    end
  end

  describe "agents page for a maintainer" do
    test "org agents are read-only, own project agents manageable, foreign hidden", %{
      conn: conn,
      user: user
    } do
      mine = project_fixture()
      foreign = project_fixture()
      join(mine, user, :maintainer)
      provider_fixture()
      org_agent = agent_fixture(%{name: "Org Agent"})
      my_agent = agent_fixture(%{name: "My Agent", scope: :project, project_id: mine.id})
      foreign_agent = agent_fixture(%{name: "Foreign", scope: :project, project_id: foreign.id})

      {:ok, view, _html} = live(conn, ~p"/settings/agents")

      assert has_element?(view, "#agent-row-#{org_agent.id}")
      refute has_element?(view, "#agent-row-#{org_agent.id} a[href$='edit']")
      assert has_element?(view, "#agent-row-#{my_agent.id} a[href$='edit']")
      refute has_element?(view, "#agent-row-#{foreign_agent.id}")
    end
  end
end
