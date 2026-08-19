defmodule CodeLead.PreviewGateway.SubdomainProxyTest do
  # async: false — flips the globally configured preview gateway.
  use CodeLead.DataCase, async: false

  import CodeLead.PreviewGatewayHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.PreviewGateway
  alias CodeLead.PreviewGateway.SubdomainProxy

  defp repo_task(preview_port) do
    project = project_fixture()
    repository = repository_fixture(project.id, %{preview_port: preview_port})
    task_fixture(project.id, %{target: :repo, repository_id: repository.id})
  end

  describe "url_for/1" do
    test "builds the task's absolute subdomain URL, eliding default ports" do
      subdomain_gateway!(domain: "preview.example.com", url: [scheme: "http", port: 80])
      task = repo_task(4001)

      assert SubdomainProxy.url_for(task) ==
               {:ok, "http://task-#{task.id}.preview.example.com/"}
    end

    test "elides 443 for https and keeps a custom port" do
      task = repo_task(4001)

      subdomain_gateway!(domain: "preview.example.com", url: [scheme: "https", port: 443])
      assert {:ok, "https://task-" <> _rest} = SubdomainProxy.url_for(task)

      subdomain_gateway!(domain: "preview.localhost", url: [scheme: "http", port: 4000])

      assert SubdomainProxy.url_for(task) ==
               {:ok, "http://task-#{task.id}.preview.localhost:4000/"}
    end

    test "passes port errors through" do
      subdomain_gateway!()

      assert SubdomainProxy.url_for(repo_task(nil)) == {:error, :no_preview_port}

      project = project_fixture()
      folder_task = task_fixture(project.id, %{target: :folder})
      assert SubdomainProxy.url_for(folder_task) == {:error, :unsupported}
    end
  end

  describe "upstream_for/1" do
    test "resolves the shared local upstream" do
      subdomain_gateway!()
      task = repo_task(4001)

      assert SubdomainProxy.upstream_for(task) == {:ok, %{host: "127.0.0.1", port: 4001}}
    end
  end

  describe "preview_env/2 under the subdomain gateway" do
    test "derives the origin from the task URL and empties the base path" do
      subdomain_gateway!(domain: "preview.localhost", url: [scheme: "http", port: 4000])
      task = repo_task(4001)

      assert PreviewGateway.preview_env(task, "http://cl.example") == [
               {"PREVIEW_BASE_PATH", ""},
               {"PREVIEW_ORIGIN", "http://task-#{task.id}.preview.localhost:4000"},
               {"PREVIEW_PORT", "4001"}
             ]
    end

    test "elides the default port in the derived origin" do
      subdomain_gateway!(domain: "preview.example.com", url: [scheme: "https", port: 443])
      task = repo_task(4001)

      assert {"PREVIEW_ORIGIN", "https://task-#{task.id}.preview.example.com"} in PreviewGateway.preview_env(
               task,
               "ignored"
             )
    end
  end
end
