defmodule CodeLeadWeb.PageControllerTest do
  use CodeLeadWeb.ConnCase

  import CodeLead.ProjectsFixtures

  test "GET / without projects renders the welcome page", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Welcome to CodeLead"
  end

  test "GET / redirects to the first project's board", %{conn: conn} do
    project = project_fixture()

    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/projects/#{project.id}/board"
  end
end
