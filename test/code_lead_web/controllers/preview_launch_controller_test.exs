defmodule CodeLeadWeb.PreviewLaunchControllerTest do
  use CodeLeadWeb.ConnCase, async: true

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  defp repo_task(preview_port) do
    project = project_fixture()
    repository = repository_fixture(project.id, %{preview_port: preview_port})

    task_fixture(project.id, %{target: :repo, repository_id: repository.id})
  end

  test "unauthenticated launch responds 401 with the branded page", %{conn: conn} do
    task = repo_task(4321)

    conn = get(conn, "/preview/launch/#{task.id}")

    assert conn.status == 401
    assert conn.resp_body =~ "Session expired"
  end

  describe "authenticated" do
    @moduletag role: :admin

    setup :register_and_log_in_user

    test "redirects onto the path-gateway URL", %{conn: conn} do
      task = repo_task(4321)

      conn = get(conn, "/preview/launch/#{task.id}")

      assert redirected_to(conn) == "/preview/#{task.id}/"
    end

    test "a task without a preview port gets the branded hint", %{conn: conn} do
      project = project_fixture()
      repository = repository_fixture(project.id, %{})
      task = task_fixture(project.id, %{target: :repo, repository_id: repository.id})

      conn = get(conn, "/preview/launch/#{task.id}")

      assert conn.status == 404
      assert conn.resp_body =~ "No preview port declared"
    end

    test "an unknown task 404s with the branded page", %{conn: conn} do
      conn = get(conn, "/preview/launch/999999")

      assert conn.status == 404
      assert conn.resp_body =~ "Task not found"
    end
  end
end
