defmodule CodeLeadWeb.AuthorizationTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AccountsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  setup :register_and_log_in_user

  describe "admin gate" do
    test "members bounce off the admin pages to /settings", %{conn: conn} do
      for path <- [~p"/settings/users", ~p"/settings/providers", ~p"/settings/organization"] do
        assert {:error, {:redirect, %{to: "/settings", flash: flash}}} = live(conn, path)
        assert flash["error"] =~ "Administrator access required"
      end
    end

    @tag role: :admin
    test "admins pass", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/settings/users")
      assert {:ok, _view, _html} = live(conn, ~p"/settings/organization")
    end

    test "admin-only tiles are hidden from members", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      refute has_element?(view, "#settings-tile-users")
      refute has_element?(view, "#settings-tile-providers")
      refute has_element?(view, "#settings-tile-organization")
      assert has_element?(view, "#settings-tile-projects")
      assert has_element?(view, "#settings-tile-agents")
    end
  end

  describe "project gate" do
    test "a non-member gets a generic not-found redirect", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      for path <- [
            ~p"/projects/#{project.id}/board",
            ~p"/projects/#{project.id}/archive",
            ~p"/projects/#{project.id}/tasks/#{task.id}",
            ~p"/settings/projects/#{project.id}"
          ] do
        assert {:error, {:redirect, %{to: "/", flash: flash}}} = live(conn, path)
        assert flash["error"] == "Project not found"
      end
    end

    test "a made-up project id takes the same refusal path", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               live(conn, ~p"/projects/999999/board")

      assert flash["error"] == "Project not found"
    end

    test "a reporter reaches the board but not the project settings", %{conn: conn, user: user} do
      project = project_fixture()
      membership_fixture(project, user, :reporter)

      assert {:ok, _view, _html} = live(conn, ~p"/projects/#{project.id}/board")

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/settings/projects/#{project.id}")

      assert to == "/projects/#{project.id}/board"
      assert flash["error"] =~ "Only maintainers can manage project settings"
    end

    test "a maintainer reaches the project settings", %{conn: conn, user: user} do
      project = project_fixture()
      membership_fixture(project, user, :maintainer)

      assert {:ok, _view, _html} = live(conn, ~p"/settings/projects/#{project.id}")
    end

    test "the artifact download is gated too", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      conn = get(conn, ~p"/projects/#{project.id}/tasks/#{task.id}/artifact")
      assert redirected_to(conn) == "/"
    end
  end

  describe "preview gate" do
    test "a non-member is refused with the minimal 401 page", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id)

      conn = get(conn, "/preview/launch/#{task.id}")
      assert conn.status == 401
    end
  end
end
