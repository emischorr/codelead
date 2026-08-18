defmodule CodeLead.PreviewGateway.PathProxyContainerTest do
  # async: false — swaps the :docker_cli config and process-global env
  # vars the fake docker script reads.
  use CodeLead.DataCase, async: false

  # Failure scenarios log by design; keep them out of the output.
  @moduletag :capture_log

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.PreviewGateway.PathProxy

  @fake_docker Path.expand("../../support/fake_docker.sh", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :docker_cli)
    log = Path.join(System.tmp_dir!(), "fake_docker_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_DOCKER_LOG", log)

    on_exit(fn ->
      Application.put_env(:code_lead, :docker_cli, original)
      System.delete_env("FAKE_DOCKER_LOG")
      System.delete_env("FAKE_DOCKER_HOST_PORT")
      System.delete_env("FAKE_DOCKER_RELAY")
      System.delete_env("FAKE_DOCKER_RELAY_TARGET")
      File.rm(log)
    end)

    %{log: log}
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

  defp log_lines(log) do
    case File.read(log) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _} -> []
    end
  end

  test "creates a relay beside the task container and resolves its host port", %{log: log} do
    use_docker("running")
    System.put_env("FAKE_DOCKER_HOST_PORT", "55001")
    task = container_task(5173)

    assert PathProxy.upstream_for(task) == {:ok, %{host: "127.0.0.1", port: 55_001}}

    run = Enum.find(log_lines(log), &String.starts_with?(&1, "run -d"))
    assert run =~ "--name codelead-preview-#{task.id}"
    assert run =~ "--network bridge"
    assert run =~ "-p 127.0.0.1:0:5173"
  end

  test "reuses a relay already forwarding to the current target", %{log: log} do
    use_docker("running")
    System.put_env("FAKE_DOCKER_RELAY", "running")
    System.put_env("FAKE_DOCKER_RELAY_TARGET", "127.0.0.1|172.17.0.5:5173")
    task = container_task(5173)

    assert PathProxy.upstream_for(task) == {:ok, %{host: "127.0.0.1", port: 55_001}}
    refute Enum.any?(log_lines(log), &String.starts_with?(&1, "run -d"))
  end

  test "an absent task container is not running" do
    use_docker("absent")
    task = container_task(5173)

    assert PathProxy.upstream_for(task) == {:error, :not_running}
  end

  test "no declared port short-circuits before docker is consulted", %{log: log} do
    use_docker("absent")
    task = container_task(nil)

    assert PathProxy.upstream_for(task) == {:error, :no_preview_port}
    assert log_lines(log) == []
  end
end
