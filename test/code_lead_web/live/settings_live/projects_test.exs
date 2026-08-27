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
    test "a plain name opens the detail page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/new")

      assert {:ok, _detail, html} =
               view
               |> form("#project-form", project: %{source: "Apollo"})
               |> render_submit()
               |> follow_redirect(conn)

      assert html =~ "Apollo"
      assert Enum.any?(Projects.list_projects(), &(&1.name == "Apollo"))
    end

    test "a github.com URL creates the project with its repository linked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/new")

      assert {:ok, _detail, html} =
               view
               |> form("#project-form", project: %{source: "https://github.com/acme/widgets"})
               |> render_submit()
               |> follow_redirect(conn)

      assert html =~ "widgets"

      project = Enum.find(Projects.list_projects(), &(&1.name == "widgets"))
      assert project

      assert [%{name: "widgets", git_url: "https://github.com/acme/widgets"}] =
               Projects.list_repositories(project.id)
    end

    test "a gitlab.com URL creates the project with its repository linked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/new")

      assert {:ok, _detail, _html} =
               view
               |> form("#project-form", project: %{source: "https://gitlab.com/acme/widgets"})
               |> render_submit()
               |> follow_redirect(conn)

      project = Enum.find(Projects.list_projects(), &(&1.name == "widgets"))
      assert project

      assert [%{git_url: "https://gitlab.com/acme/widgets"}] =
               Projects.list_repositories(project.id)
    end

    test "an unrecognized URL is rejected instead of becoming the name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/projects/new")

      html =
        view
        |> form("#project-form", project: %{source: "https://example.com/acme/widgets"})
        |> render_change()

      assert html =~ "only github.com and gitlab.com repository URLs are auto-detected"

      view
      |> form("#project-form", project: %{source: "https://example.com/acme/widgets"})
      |> render_submit()

      refute Enum.any?(Projects.list_projects(), &(&1.name == "widgets"))
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
