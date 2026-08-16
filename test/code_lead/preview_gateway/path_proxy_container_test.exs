defmodule CodeLead.PreviewGateway.PathProxyContainerTest do
  # async: false — swaps the :docker_cli config and process-global env
  # vars the fake docker script reads.
  use CodeLead.DataCase, async: false

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.PreviewGateway.PathProxy

  @fake_docker Path.expand("../../support/fake_docker.sh", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :docker_cli)

    on_exit(fn ->
      Application.put_env(:code_lead, :docker_cli, original)
      System.delete_env("FAKE_DOCKER_HOST_PORT")
    end)

    :ok
  end

  defp use_docker(scenario) do
    Application.put_env(:code_lead, :docker_cli, ["sh", @fake_docker, scenario])
  end

  defp container_task(preview_port) do
    project = project_fixture()
    repository = repository_fixture(project.id, %{preview_port: preview_port})

    project.id
    |> task_fixture(%{target: :repo, repository_id: repository.id})
    |> put_context!(%{execution_env: :container})
  end

  test "resolves the published host port via docker port" do
    use_docker("running_published")
    System.put_env("FAKE_DOCKER_HOST_PORT", "55001")
    task = container_task(5173)

    assert PathProxy.upstream_for(task) == {:ok, %{host: "127.0.0.1", port: 55_001}}
  end

  test "an absent container (or unpublished port) is not running" do
    use_docker("absent")
    task = container_task(5173)

    assert PathProxy.upstream_for(task) == {:error, :not_running}
  end

  test "no declared port short-circuits before docker is consulted" do
    use_docker("absent")
    task = container_task(nil)

    assert PathProxy.upstream_for(task) == {:error, :no_preview_port}
  end
end
