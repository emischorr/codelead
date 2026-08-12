defmodule CodeLeadWeb.TaskArtifactControllerTest do
  use CodeLeadWeb.ConnCase, async: true

  import CodeLead.AgentsFixtures
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Workspace

  defp folder_task(project) do
    agent = agent_fixture(%{driver: :llm_api, work_type: :content, roles: [:execute]})

    task =
      task_fixture(project.id, %{
        title: "Hero copy",
        work_type: :content,
        target: :folder,
        agent_id: agent.id
      })

    folder = Workspace.task_folder(task.id)
    File.mkdir_p!(Path.join(folder, "drafts"))
    File.write!(Path.join(folder, "output.md"), "# Copy\n")
    File.write!(Path.join([folder, "drafts", "v1.md"]), "draft\n")
    on_exit(fn -> File.rm_rf!(folder) end)

    task
  end

  describe "unauthenticated" do
    test "redirects to the log-in page", %{conn: conn} do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content, target: :folder})

      conn = get(conn, ~p"/projects/#{project.id}/tasks/#{task.id}/artifact")

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "authenticated" do
    setup :register_and_log_in_user

    setup do
      %{project: project_fixture()}
    end

    test "sends the task folder as a zip", %{conn: conn, project: project} do
      task = folder_task(project)

      conn = get(conn, ~p"/projects/#{project.id}/tasks/#{task.id}/artifact")

      assert response_content_type(conn, :zip) =~ "application/zip"

      assert get_resp_header(conn, "content-disposition") |> hd() =~
               "task-#{task.id}-hero-copy.zip"

      # The archive unpacks into its own directory, nested files included.
      assert {:ok, entries} = :zip.list_dir(conn.resp_body)
      names = for {:zip_file, name, _info, _c, _o, _s} <- entries, do: to_string(name)
      assert "task-#{task.id}-hero-copy/output.md" in names
      assert "task-#{task.id}-hero-copy/drafts/v1.md" in names
    end

    test "redirects a repo-target task, which has no artifact", %{conn: conn, project: project} do
      repository = repository_fixture(project.id)

      task =
        task_fixture(project.id, %{
          work_type: :code,
          target: :repo,
          repository_id: repository.id
        })

      conn = get(conn, ~p"/projects/#{project.id}/tasks/#{task.id}/artifact")

      assert redirected_to(conn) == ~p"/projects/#{project.id}/tasks/#{task.id}"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no downloadable artifact"
    end

    test "redirects when the folder was never provisioned", %{conn: conn, project: project} do
      task = task_fixture(project.id, %{work_type: :content, target: :folder})

      conn = get(conn, ~p"/projects/#{project.id}/tasks/#{task.id}/artifact")

      assert redirected_to(conn) == ~p"/projects/#{project.id}/tasks/#{task.id}"
    end

    test "redirects when the project in the path is not the task's", %{
      conn: conn,
      project: project
    } do
      task = folder_task(project)
      other = project_fixture()

      conn = get(conn, ~p"/projects/#{other.id}/tasks/#{task.id}/artifact")

      assert redirected_to(conn) == ~p"/projects/#{other.id}/tasks/#{task.id}"
    end
  end
end
