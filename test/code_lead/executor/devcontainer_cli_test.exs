defmodule CodeLead.Executor.DevcontainerCliTest do
  # async: false — swaps the :devcontainer_cli config and process-global
  # env vars the fake devcontainer script reads.
  use ExUnit.Case, async: false

  alias CodeLead.Executor.DevcontainerCli

  @fake Path.expand("../../support/fake_devcontainer.sh", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :devcontainer_cli)

    log =
      Path.join(System.tmp_dir!(), "fake_devcontainer_#{System.unique_integer([:positive])}.log")

    System.put_env("FAKE_DEVCONTAINER_LOG", log)

    on_exit(fn ->
      Application.put_env(:code_lead, :devcontainer_cli, original)
      System.delete_env("FAKE_DEVCONTAINER_LOG")
      System.delete_env("FAKE_DEVCONTAINER_COMPOSE_PROJECT")
      File.rm(log)
    end)

    %{log: log}
  end

  defp use_devcontainer(scenario) do
    Application.put_env(:code_lead, :devcontainer_cli, ["sh", @fake, scenario])
  end

  defp log_lines(log) do
    case File.read(log) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _} -> []
    end
  end

  test "cli/0 errors when the configured head is not on PATH" do
    Application.put_env(:code_lead, :devcontainer_cli, ["definitely-not-a-real-cli"])

    assert DevcontainerCli.cli() == {:error, :devcontainer_cli_not_found}
    refute DevcontainerCli.available?()
  end

  test "up/2 builds the argv and parses the result", %{log: log} do
    use_devcontainer("success")

    assert {:ok, result} =
             DevcontainerCli.up("/ws/task-1",
               id_labels: [{"codelead.task_id", 1}],
               mounts: ["type=bind,source=/data,target=/data"],
               config: "/ws/task-1/.devcontainer/devcontainer.json"
             )

    assert result.container_id == "f4k3devc0ntainer"
    assert result.compose_project == nil
    assert result.remote_user == "root"

    [line] = log_lines(log)
    assert line =~ "up --workspace-folder /ws/task-1 --log-format json"
    assert line =~ "--id-label codelead.task_id=1"
    assert line =~ "--mount type=bind,source=/data,target=/data"
    assert line =~ "--config /ws/task-1/.devcontainer/devcontainer.json"
  end

  test "up/2 omits --config when discovery is left to the CLI", %{log: log} do
    use_devcontainer("success")

    assert {:ok, _result} = DevcontainerCli.up("/ws/task-1")
    refute hd(log_lines(log)) =~ "--config"
  end

  test "up/2 surfaces the compose project of a compose-based config" do
    use_devcontainer("success_compose")
    System.put_env("FAKE_DEVCONTAINER_COMPOSE_PROJECT", "task-7_devcontainer")

    assert {:ok, %{compose_project: "task-7_devcontainer"}} = DevcontainerCli.up("/ws/task-7")
  end

  test "a missing config surfaces the CLI's error message" do
    use_devcontainer("config_error")

    assert {:error, {:devcontainer_up_failed, message, _tail}} = DevcontainerCli.up("/ws/task-1")
    assert message =~ "not found"
  end

  test "a failed build carries the log tail for the failure detail" do
    use_devcontainer("build_fails")

    assert {:error, {:devcontainer_up_failed, message, tail}} = DevcontainerCli.up("/ws/task-1")
    assert message =~ "docker buildx build"
    assert tail =~ "failed to solve"
  end

  test "progress events stream past without disturbing the result" do
    use_devcontainer("slow")

    assert {:ok, %{container_id: "f4k3devc0ntainer", remote_user: "vscode"}} =
             DevcontainerCli.up("/ws/task-1")
  end
end
