defmodule CodeLead.PreviewGateway.PathProxyTest do
  use CodeLead.DataCase, async: true

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.PreviewGateway.PathProxy

  describe "url_for/1" do
    test "repo task with a declared port gets the trailing-slash prefix" do
      task = repo_task(%{preview_port: 5173})

      assert PathProxy.url_for(task) == {:ok, "/preview/#{task.id}/"}
    end

    test "repo task without a declared port has no preview" do
      task = repo_task(%{})

      assert PathProxy.url_for(task) == {:error, :no_preview_port}
    end

    test "repo task without a repository has no preview" do
      project = project_fixture()
      task = task_fixture(project.id, %{target: :repo})

      assert PathProxy.url_for(%{task | repository_id: nil}) == {:error, :no_preview_port}
    end

    test "folder tasks are unsupported" do
      project = project_fixture()
      task = task_fixture(project.id, %{work_type: :content, target: :folder})

      assert PathProxy.url_for(task) == {:error, :unsupported}
    end
  end

  describe "upstream_for/1 (local)" do
    test "resolves to loopback on the declared port" do
      task = repo_task(%{preview_port: 4001})

      assert PathProxy.upstream_for(task) == {:ok, %{host: "127.0.0.1", port: 4001}}
    end

    test "propagates the missing port" do
      task = repo_task(%{})

      assert PathProxy.upstream_for(task) == {:error, :no_preview_port}
    end
  end

  defp repo_task(repo_attrs) do
    project = project_fixture()
    repository = repository_fixture(project.id, repo_attrs)

    task_fixture(project.id, %{target: :repo, repository_id: repository.id})
  end
end
