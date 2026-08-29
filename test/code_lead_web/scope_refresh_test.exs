defmodule CodeLeadWeb.ScopeRefreshTest do
  use CodeLeadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeLead.AccountsFixtures
  import CodeLead.ProjectsFixtures

  alias CodeLead.Accounts

  setup :register_and_log_in_user

  defp maintainer_scope(project) do
    maintainer = user_fixture()
    membership_fixture(project, maintainer, :maintainer)
    user_scope_fixture(maintainer)
  end

  test "losing membership on the open project navigates away", %{conn: conn, user: user} do
    project = project_fixture()
    manager = maintainer_scope(project)
    {:ok, membership} = Accounts.add_project_member(manager, project.id, user.id, :member)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

    {:ok, _} = Accounts.remove_project_member(manager, membership)

    assert_redirect(view, "/")
  end

  test "a role change on another project updates the sidebar in place", %{
    conn: conn,
    user: user
  } do
    project = project_fixture()
    other = project_fixture(%{name: "Other"})
    manager = maintainer_scope(project)
    other_manager = maintainer_scope(other)
    {:ok, _} = Accounts.add_project_member(manager, project.id, user.id, :member)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")
    refute has_element?(view, "#project-switcher", "Other")

    {:ok, _} = Accounts.add_project_member(other_manager, other.id, user.id, :member)

    # The switcher's project list is rebuilt without a remount.
    assert render(view)
    assert has_element?(view, "#nav-board")
  end

  test "an instance-role change forces a remount", %{conn: conn, user: user} do
    project = project_fixture()
    manager = maintainer_scope(project)
    {:ok, _} = Accounts.add_project_member(manager, project.id, user.id, :member)
    admin = user_scope_fixture(admin_fixture())

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/board")

    {:ok, _} = Accounts.update_user_role(admin, user, :admin)

    assert_redirect(view, "/")
  end
end
