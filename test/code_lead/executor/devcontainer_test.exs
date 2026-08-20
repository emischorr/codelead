defmodule CodeLead.Executor.DevcontainerTest do
  # async: false — swaps the :docker_cli/:devcontainer_cli configs and
  # process-global env vars the fake scripts read.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor.Context
  alias CodeLead.Executor.Devcontainer
  alias CodeLead.Workspace

  @fake_docker Path.expand("../../support/fake_docker.sh", __DIR__)
  @fake_devcontainer Path.expand("../../support/fake_devcontainer.sh", __DIR__)

  setup do
    original_docker = Application.get_env(:code_lead, :docker_cli)
    original_devcontainer = Application.get_env(:code_lead, :devcontainer_cli)
    original_version = Application.get_env(:code_lead, :harness_version)
    unique = System.unique_integer([:positive])
    docker_log = Path.join(System.tmp_dir!(), "fake_docker_#{unique}.log")
    devcontainer_log = Path.join(System.tmp_dir!(), "fake_devcontainer_#{unique}.log")
    System.put_env("FAKE_DOCKER_LOG", docker_log)
    System.put_env("FAKE_DEVCONTAINER_LOG", devcontainer_log)

    on_exit(fn ->
      Application.put_env(:code_lead, :docker_cli, original_docker)
      Application.put_env(:code_lead, :devcontainer_cli, original_devcontainer)
      Application.put_env(:code_lead, :harness_version, original_version)
      System.delete_env("FAKE_DOCKER_LOG")
      System.delete_env("FAKE_DEVCONTAINER_LOG")
      System.delete_env("FAKE_DOCKER_METADATA")
      System.delete_env("FAKE_DOCKER_COMPOSE_PROJECT")
      File.rm(docker_log)
      File.rm(devcontainer_log)
    end)

    %{docker_log: docker_log, devcontainer_log: devcontainer_log}
  end

  defp use_docker(scenario) do
    Application.put_env(:code_lead, :docker_cli, ["sh", @fake_docker, scenario])
  end

  defp use_devcontainer(scenario) do
    Application.put_env(:code_lead, :devcontainer_cli, ["sh", @fake_devcontainer, scenario])
  end

  # The fake probe answers glibc unless FAKE_DOCKER_LIBC says otherwise,
  # so tests pre-stage the glibc flavor: wrapper plus the bun sibling
  # that marks a staged runtime as complete.
  defp stage_harness! do
    Application.put_env(:code_lead, :harness_version, "test")
    binary = Workspace.harness_binary("test", :glibc)
    File.mkdir_p!(Path.dirname(binary))
    File.write!(binary, "#!/bin/sh\n")
    File.write!(Path.join(Path.dirname(binary), "bun"), "a-bun")
    binary
  end

  defp container_task_setup(attrs \\ %{}, opts \\ []) do
    project = project_fixture()
    git_url = create_origin!()

    if Keyword.get(opts, :seed_config, true) do
      commit_on_origin!(git_url, ".devcontainer/devcontainer.json", ~s({"image": "alpine"}))
    end

    repository =
      repository_fixture(
        project.id,
        Map.merge(
          %{git_url: git_url, default_branch: "main", env_kind: :devcontainer},
          attrs
        )
      )

    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      task_fixture(project.id, %{
        title: "Containerized work",
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: executor.id,
        execution_env: :container
      })

    %{project: project, repository: repository, task: task}
  end

  defp log_lines(log) do
    case File.read(log) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _} -> []
    end
  end

  # A round-trip through the bridged agent proves the exec ran (and
  # therefore logged) before the test reads the log — closing the port
  # right after opening it would race the script's startup.
  defp await_agent(port) do
    Port.command(port, ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n))
    assert_receive {^port, {:data, _data}}, 5_000
    Port.close(port)
  end

  describe "provision/1" do
    test "refuses before any docker or git work when the repo declares no devcontainer env",
         %{docker_log: docker_log, devcontainer_log: devcontainer_log} do
      use_docker("running")
      use_devcontainer("success")

      %{task: task, repository: repository} = container_task_setup(%{env_kind: :default})

      assert {:error, {:missing_execution_env, name}} = Devcontainer.provision(task)
      assert name == repository.name
      assert log_lines(docker_log) == []
      assert log_lines(devcontainer_log) == []
      refute File.dir?(Workspace.worktree_path(task.id))
    end

    test "refuses under a legacy non-coincident workspace mount before touching the CLI",
         %{devcontainer_log: devcontainer_log} do
      use_docker("running")
      use_devcontainer("success")
      %{task: task} = container_task_setup()

      original = Application.get_env(:code_lead, :workspace_volume)
      Application.put_env(:code_lead, :workspace_volume, "codelead-data")
      on_exit(fn -> Application.put_env(:code_lead, :workspace_volume, original) end)

      assert {:error, :workspace_not_host_coincident} = Devcontainer.provision(task)
      assert log_lines(devcontainer_log) == []
    end

    test "refuses when the cloned worktree carries no devcontainer config",
         %{devcontainer_log: devcontainer_log} do
      use_docker("running")
      use_devcontainer("success")

      %{task: task, repository: repository} = container_task_setup(%{}, seed_config: false)

      assert {:error, {:missing_devcontainer_config, name}} = Devcontainer.provision(task)
      assert name == repository.name
      assert log_lines(devcontainer_log) == []
    end

    test "provisions worktree and agent home, then runs devcontainer up with identity and mount",
         %{devcontainer_log: devcontainer_log} do
      use_docker("running")
      use_devcontainer("success")
      %{task: task} = container_task_setup()

      assert {:ok, %Context{} = context} = Devcontainer.provision(task)

      assert context.executor == Devcontainer
      assert context.exec_ref == "f4k3devc0ntainer"
      assert File.dir?(context.path)
      assert File.dir?(Path.join(Workspace.agent_home(task.id), ".tmp"))

      [up] = log_lines(devcontainer_log)
      assert up =~ "up --workspace-folder #{context.path}"
      assert up =~ "--id-label codelead.managed=true"
      assert up =~ "--id-label codelead.task_container=true"
      assert up =~ "--id-label codelead.task_id=#{task.id}"
      assert up =~ "--id-label codelead.project_id=#{task.project_id}"
      assert up =~ "--mount type=bind,source="
      refute up =~ "--config"
    end

    test "an explicit devcontainer_path is passed as --config and must exist",
         %{devcontainer_log: devcontainer_log} do
      use_docker("running")
      use_devcontainer("success")

      %{task: task} =
        container_task_setup(%{devcontainer_path: ".devcontainer/devcontainer.json"})

      assert {:ok, %Context{path: path}} = Devcontainer.provision(task)
      assert hd(log_lines(devcontainer_log)) =~ "--config #{path}/.devcontainer/devcontainer.json"
    end

    test "an explicit devcontainer_path pointing at nothing refuses" do
      use_docker("running")
      use_devcontainer("success")

      %{task: task} = container_task_setup(%{devcontainer_path: ".devcontainer/other.json"})

      assert {:error, {:missing_devcontainer_config, _name}} = Devcontainer.provision(task)
    end

    test "an up failure surfaces the CLI's message" do
      use_docker("running")
      use_devcontainer("build_fails")
      %{task: task} = container_task_setup()

      assert {:error, {:devcontainer_up_failed, message, _tail}} = Devcontainer.provision(task)
      assert message =~ "docker buildx build"
    end

    test "non-repo targets are unsupported" do
      project = project_fixture()
      task = task_fixture(project.id, %{target: :folder})

      assert Devcontainer.provision(task) == {:error, :container_target_unsupported}
    end
  end

  describe "available?/1" do
    test "ok when both CLIs resolve and the harness version is configured" do
      use_docker("running")
      use_devcontainer("success")
      Application.put_env(:code_lead, :harness_version, "test")

      assert Devcontainer.available?(["claude-agent-acp"]) == :ok
    end

    test "a missing devcontainer CLI is reported before any provisioning" do
      use_docker("running")
      Application.put_env(:code_lead, :devcontainer_cli, ["definitely-not-a-real-cli"])
      Application.put_env(:code_lead, :harness_version, "test")

      assert Devcontainer.available?(["claude-agent-acp"]) ==
               {:error, :devcontainer_cli_not_found}
    end

    test "anything but the claude harness is unsupported" do
      use_docker("running")
      use_devcontainer("success")

      assert Devcontainer.available?(["codex-acp"]) ==
               {:error, {:container_command_unsupported, "codex-acp"}}
    end
  end

  describe "spawn/3" do
    test "bridges JSON-RPC through docker exec into the resolved container",
         %{docker_log: docker_log} do
      use_docker("running+happy")
      use_devcontainer("success")
      binary = stage_harness!()
      %{task: task} = container_task_setup()
      {:ok, context} = Devcontainer.provision(task)
      context = %{context | env: [{"PROJECT_KEY", "value"}]}

      assert {:ok, port} = Devcontainer.spawn(context, ["claude-agent-acp"])
      await_agent(port)

      exec = Enum.find(log_lines(docker_log), &String.contains?(&1, binary))
      assert exec =~ "exec -i -w #{context.path}"
      assert exec =~ "-e PROJECT_KEY=value"
      assert exec =~ "-e HOME=#{Workspace.agent_home(task.id)}"
      assert exec =~ "f4k3devc0ntainer #{binary}"
      refute exec =~ "--user"
    end

    test "execs as the devcontainer's remote user when the config names one",
         %{docker_log: docker_log} do
      use_docker("running+happy")
      use_devcontainer("success")
      System.put_env("FAKE_DOCKER_METADATA", ~s([{"remoteUser":"node"}]))
      binary = stage_harness!()
      %{task: task} = container_task_setup()
      {:ok, context} = Devcontainer.provision(task)

      assert {:ok, port} = Devcontainer.spawn(context, ["claude-agent-acp"])
      await_agent(port)

      exec = Enum.find(log_lines(docker_log), &String.contains?(&1, binary))
      assert exec =~ "--user node"
    end

    test "self-heals an externally removed environment by re-running up",
         %{devcontainer_log: devcontainer_log} do
      use_docker("running")
      use_devcontainer("success")
      stage_harness!()
      %{task: task} = container_task_setup()
      {:ok, context} = Devcontainer.provision(task)
      File.rm!(devcontainer_log)

      use_docker("absent+happy")

      assert {:ok, port} = Devcontainer.spawn(context, ["claude-agent-acp"])
      await_agent(port)

      assert [up] = log_lines(devcontainer_log)
      assert up =~ "up --workspace-folder #{context.path}"
    end

    test "an unsupported command is refused" do
      use_docker("running")
      use_devcontainer("success")
      %{task: task} = container_task_setup()
      {:ok, context} = Devcontainer.provision(task)

      assert Devcontainer.spawn(context, ["codex-acp"]) ==
               {:error, {:container_command_unsupported, "codex-acp"}}
    end
  end

  describe "teardown/2" do
    test "keep: true removes environment and relay but keeps worktree and agent home",
         %{docker_log: docker_log} do
      use_docker("running")
      use_devcontainer("success")
      %{task: task} = container_task_setup()
      {:ok, context} = Devcontainer.provision(task)

      assert :ok = Devcontainer.teardown(context, keep: true)

      lines = log_lines(docker_log)
      assert Enum.any?(lines, &String.starts_with?(&1, "rm -f codelead-preview-#{task.id}"))
      assert Enum.any?(lines, &String.starts_with?(&1, "rm -f f4k3devc0ntainer"))
      refute Enum.any?(lines, &String.starts_with?(&1, "compose"))
      assert File.dir?(context.path)
      assert File.dir?(Workspace.agent_home(task.id))
    end

    test "a compose-based environment goes down as a whole project", %{docker_log: docker_log} do
      use_docker("running")
      use_devcontainer("success_compose")
      System.put_env("FAKE_DOCKER_COMPOSE_PROJECT", "task-9_devcontainer")
      %{task: task} = container_task_setup()
      {:ok, context} = Devcontainer.provision(task)

      assert :ok = Devcontainer.teardown(context, keep: true)

      assert Enum.any?(
               log_lines(docker_log),
               &String.starts_with?(&1, "compose -p task-9_devcontainer down --volumes")
             )
    end

    test "keep: false removes environment, agent home, worktree and branch",
         %{docker_log: docker_log} do
      use_docker("running")
      use_devcontainer("success")
      %{task: task} = container_task_setup()
      {:ok, context} = Devcontainer.provision(task)

      assert :ok = Devcontainer.teardown(context, keep: false)

      assert Enum.any?(log_lines(docker_log), &String.starts_with?(&1, "rm -f f4k3devc0ntainer"))
      refute File.dir?(Workspace.agent_home(task.id))
      refute File.dir?(context.path)
    end

    test "keep: false surfaces a worktree the server cannot delete" do
      use_docker("running")
      use_devcontainer("success")
      %{task: task} = container_task_setup()
      {:ok, context} = Devcontainer.provision(task)

      # A subtree the app's own uid cannot delete — what the container
      # agent leaves behind as root. The fake docker's `run` is inert,
      # so the remover's escalation changes nothing here.
      locked = Path.join([context.path, "blocked", "locked"])
      File.mkdir_p!(locked)
      File.write!(Path.join(locked, "file.txt"), "unremovable")
      File.chmod!(locked, 0o555)

      on_exit(fn ->
        _ = File.chmod(locked, 0o755)
        _ = File.rm_rf(context.path)
      end)

      assert {:error, {:leftover, leftover}} = Devcontainer.teardown(context, keep: false)
      assert leftover == context.path

      # The rest of the discard still ran: environment and agent home gone.
      refute File.dir?(Workspace.agent_home(task.id))
    end
  end

  describe "ensure_for_task/1" do
    test "a running environment resolves without touching the CLI",
         %{devcontainer_log: devcontainer_log} do
      use_docker("running")
      use_devcontainer("success")
      %{task: task} = container_task_setup()
      {:ok, _context} = Devcontainer.provision(task)
      File.rm!(devcontainer_log)

      assert Devcontainer.ensure_for_task(task.id) == {:ok, "f4k3devc0ntainer"}
      assert log_lines(devcontainer_log) == []
    end

    test "a stopped environment is re-upped", %{devcontainer_log: devcontainer_log} do
      use_docker("running")
      use_devcontainer("success")
      %{task: task} = container_task_setup()
      {:ok, _context} = Devcontainer.provision(task)
      File.rm!(devcontainer_log)

      use_docker("stopped")

      assert Devcontainer.ensure_for_task(task.id) == {:ok, "f4k3devc0ntainer"}
      assert [up] = log_lines(devcontainer_log)
      assert up =~ "up --workspace-folder"
    end
  end

  describe "diagnose/1" do
    test "reports external removal when the environment is absent" do
      use_docker("absent")
      assert {:ok, detail} = Devcontainer.diagnose(123)
      assert detail =~ "removed externally"
    end

    test "reports an exited container" do
      use_docker("stopped")
      assert {:ok, detail} = Devcontainer.diagnose(123)
      assert detail =~ "exited"
    end

    test "stays silent when the environment is running" do
      use_docker("running")
      assert Devcontainer.diagnose(123) == :none
    end
  end
end
