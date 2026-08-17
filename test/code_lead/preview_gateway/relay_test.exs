defmodule CodeLead.PreviewGateway.RelayTest do
  # async: false — swaps the :docker_cli config and process-global env
  # vars the fake docker script reads.
  use ExUnit.Case, async: false

  alias CodeLead.PreviewGateway.Relay

  @fake_docker Path.expand("../../support/fake_docker.sh", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :docker_cli)
    log = Path.join(System.tmp_dir!(), "fake_docker_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_DOCKER_LOG", log)

    on_exit(fn ->
      Application.put_env(:code_lead, :docker_cli, original)
      Application.delete_env(:code_lead, :preview_publish_ip)
      System.delete_env("FAKE_DOCKER_LOG")
      System.delete_env("FAKE_DOCKER_HOST_PORT")
      System.delete_env("FAKE_DOCKER_TASK_IP")
      System.delete_env("FAKE_DOCKER_RELAY")
      System.delete_env("FAKE_DOCKER_RELAY_TARGET")
      File.rm(log)
    end)

    %{log: log}
  end

  defp use_docker(scenario) do
    Application.put_env(:code_lead, :docker_cli, ["sh", @fake_docker, scenario])
  end

  defp log_lines(log) do
    case File.read(log) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _} -> []
    end
  end

  test "creates a labeled relay on the task container's network", %{log: log} do
    use_docker("running")

    assert Relay.ensure(42, "codelead-task-42", 5173) == {:ok, 55_001}

    run = Enum.find(log_lines(log), &String.starts_with?(&1, "run -d"))
    assert run =~ "--name codelead-preview-42"
    assert run =~ "--label codelead.managed=true"
    assert run =~ "--label codelead.task_id=42"
    assert run =~ "--label codelead.preview_relay=true"
    assert run =~ "--label codelead.preview_target=127.0.0.1|172.17.0.5:5173"
    assert run =~ "--network bridge -p 127.0.0.1:0:5173"
    assert run =~ "tcp-listen:5173,fork,reuseaddr tcp:172.17.0.5:5173"
  end

  test "reuses a running relay whose target matches", %{log: log} do
    use_docker("running")
    System.put_env("FAKE_DOCKER_RELAY", "running")
    System.put_env("FAKE_DOCKER_RELAY_TARGET", "127.0.0.1|172.17.0.5:5173")

    assert Relay.ensure(42, "codelead-task-42", 5173) == {:ok, 55_001}

    lines = log_lines(log)
    refute Enum.any?(lines, &String.starts_with?(&1, "run -d"))
    refute Enum.any?(lines, &String.starts_with?(&1, "rm -f"))
  end

  test "recreates the relay when the task container's ip drifted", %{log: log} do
    use_docker("running")
    System.put_env("FAKE_DOCKER_RELAY", "running")
    System.put_env("FAKE_DOCKER_RELAY_TARGET", "127.0.0.1|172.17.0.9:5173")

    assert Relay.ensure(42, "codelead-task-42", 5173) == {:ok, 55_001}

    lines = log_lines(log)
    assert Enum.any?(lines, &String.starts_with?(&1, "rm -f codelead-preview-42"))
    assert Enum.find(lines, &String.starts_with?(&1, "run -d")) =~ "tcp:172.17.0.5:5173"
  end

  test "recreates the relay when the publish ip changed", %{log: log} do
    use_docker("running")
    Application.put_env(:code_lead, :preview_publish_ip, "172.17.0.1")
    System.put_env("FAKE_DOCKER_RELAY", "running")
    System.put_env("FAKE_DOCKER_RELAY_TARGET", "127.0.0.1|172.17.0.5:5173")

    assert Relay.ensure(42, "codelead-task-42", 5173) == {:ok, 55_001}

    lines = log_lines(log)
    assert Enum.any?(lines, &String.starts_with?(&1, "rm -f codelead-preview-42"))
    assert Enum.find(lines, &String.starts_with?(&1, "run -d")) =~ "-p 172.17.0.1:0:5173"
  end

  test "recreates a stopped relay", %{log: log} do
    use_docker("running")
    System.put_env("FAKE_DOCKER_RELAY", "stopped")
    System.put_env("FAKE_DOCKER_RELAY_TARGET", "127.0.0.1|172.17.0.5:5173")

    assert Relay.ensure(42, "codelead-task-42", 5173) == {:ok, 55_001}

    lines = log_lines(log)
    assert Enum.any?(lines, &String.starts_with?(&1, "rm -f codelead-preview-42"))
    assert Enum.any?(lines, &String.starts_with?(&1, "run -d"))
  end

  test "an absent task container is not running", %{log: log} do
    use_docker("absent")

    assert Relay.ensure(42, "codelead-task-42", 5173) == {:error, :not_running}
    refute Enum.any?(log_lines(log), &String.starts_with?(&1, "run -d"))
  end

  test "remove/1 force-removes the relay by name", %{log: log} do
    use_docker("running")

    assert Relay.remove(42) == :ok
    assert Enum.any?(log_lines(log), &String.starts_with?(&1, "rm -f codelead-preview-42"))
  end
end
