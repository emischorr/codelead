defmodule CodeLead.PreviewGatewayTest do
  use CodeLead.DataCase, async: true

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.PreviewGateway

  defp repo_task(preview_port) do
    project = project_fixture()
    repository = repository_fixture(project.id, %{preview_port: preview_port})
    task_fixture(project.id, %{target: :repo, repository_id: repository.id})
  end

  describe "preview_env/2" do
    test "exports base path, origin, and the declared port" do
      task = repo_task(4001)

      assert PreviewGateway.preview_env(task, "http://cl.example") == [
               {"PREVIEW_BASE_PATH", "/preview/#{task.id}"},
               {"PREVIEW_ORIGIN", "http://cl.example"},
               {"PREVIEW_PORT", "4001"}
             ]
    end

    test "exports nothing without a declared port" do
      assert PreviewGateway.preview_env(repo_task(nil), "http://cl.example") == []
    end
  end

  describe "preview_port/1" do
    test "resolves the repository's declared port" do
      assert PreviewGateway.preview_port(repo_task(4001)) == {:ok, 4001}
      assert PreviewGateway.preview_port(repo_task(nil)) == {:error, :no_preview_port}
    end

    test "non-repo targets are unsupported" do
      project = project_fixture()
      task = task_fixture(project.id, %{target: :folder})

      assert PreviewGateway.preview_port(task) == {:error, :unsupported}
    end
  end
end
