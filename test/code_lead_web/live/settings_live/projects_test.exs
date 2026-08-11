defmodule CodeLeadWeb.SettingsLive.ProjectsTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Projects

  setup :register_and_log_in_user

  describe "list" do
    test "shows each project with its counts", %{conn: conn} do
      project = project_fixture()
      repository_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/settings/projects")

      row = render(element(view, "#project-row-#{project.id}"))
      assert row =~ project.name
      assert row =~ "1 repository"
      assert row =~ "0 tasks"
    end
  end

  describe "create" do
    test "opens the detail page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/new")

      assert {:ok, _detail, html} =
               view
               |> form("#project-form", project: %{name: "Apollo"})
               |> render_submit()
               |> follow_redirect(conn)

      assert html =~ "Apollo"
      assert Enum.any?(Projects.list_projects(), &(&1.name == "Apollo"))
    end
  end

  describe "delete" do
    test "is blocked while the project has tasks", %{conn: conn} do
      project = project_fixture()
      task_fixture(project.id)

      {:ok, view, _html} = live(conn, ~p"/settings/projects")

      assert has_element?(view, "#delete-project-#{project.id}[disabled]")
    end

    test "removes an empty project", %{conn: conn} do
      project = project_fixture()

      {:ok, view, _html} = live(conn, ~p"/settings/projects")

      view |> element("#delete-project-#{project.id}") |> render_click()

      refute has_element?(view, "#project-row-#{project.id}")
    end
  end
end
