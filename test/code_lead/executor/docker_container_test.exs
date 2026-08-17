defmodule CodeLead.Executor.DockerContainerTest do
  # async: false — swaps the :docker_cli config and process-global env
  # vars the fake docker script reads.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor.Context
  alias CodeLead.Executor.DockerContainer
  alias CodeLead.Workspace

  @fake_docker Path.expand("../../support/fake_docker.sh", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :docker_cli)
    original_version = Application.get_env(:code_lead, :harness_version)
    log = Path.join(System.tmp_dir!(), "fake_docker_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_DOCKER_LOG", log)

    on_exit(fn ->
      Application.put_env(:code_lead, :docker_cli, original)
      Application.put_env(:code_lead, :harness_version, original_version)
      System.delete_env("FAKE_DOCKER_LOG")
      System.delete_env("FAKE_DOCKER_IMAGE")
      File.rm(log)
    end)

    %{log: log}
  end

  defp use_docker(scenario) do
    Application.put_env(:code_lead, :docker_cli, ["sh", @fake_docker, scenario])
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

  # A version nothing has staged, with no baked source — the shape a
  # fresh dev instance is in before its first container run.
  defp unstaged_version! do
    version = "0.0.#{System.unique_integer([:positive])}"
    original_source = Application.get_env(:code_lead, :harness_source)
    Application.put_env(:code_lead, :harness_version, version)
    Application.put_env(:code_lead, :harness_source, "/definitely/not/here")
    on_exit(fn -> Application.put_env(:code_lead, :harness_source, original_source) end)
    version
  end

  defp container_task_setup(attrs \\ %{}) do
    project = project_fixture()
    git_url = create_origin!()

    repository =
      repository_fixture(
        project.id,
        Map.merge(
          %{git_url: git_url, default_branch: "main", env_kind: :image, image_ref: "acme/dev:1"},
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

    System.put_env("FAKE_DOCKER_IMAGE", repository.image_ref || "")
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
    test "refuses before any docker or git work when no image is declared", %{log: log} do
      use_docker("absent")

      %{task: task, repository: repository} =
        container_task_setup(%{env_kind: :default, image_ref: nil})

      assert {:error, {:missing_execution_env, name}} = DockerContainer.provision(task)
      assert name == repository.name
      assert log_lines(log) == []
      refute File.dir?(Workspace.worktree_path(task.id))
    end

    test ":image with a blank ref refuses the same way" do
      use_docker("absent")
      %{task: task} = container_task_setup()

      # Bypasses the changeset on purpose: this is the defense-in-depth
      # path for a row that predates the image_ref validation.
      task.repository_id
      |> CodeLead.Projects.get_repository!()
      |> Ecto.Changeset.change(image_ref: nil)
      |> CodeLead.Repo.update!()

      assert {:error, {:missing_execution_env, _name}} = DockerContainer.provision(task)
    end

    test "provisions worktree, agent home, and creates + starts a labeled container", %{log: log} do
      use_docker("absent")
      %{task: task} = container_task_setup()

      assert {:ok, %Context{} = context} = DockerContainer.provision(task)

      assert context.executor == DockerContainer
      assert context.exec_ref == "codelead-task-#{task.id}"
      assert File.dir?(context.path)
      assert File.dir?(Workspace.agent_home(task.id))
      assert File.dir?(Path.join(Workspace.agent_home(task.id), ".tmp"))

      lines = log_lines(log)
      create = Enum.find(lines, &String.starts_with?(&1, "create "))
      assert create =~ "--name codelead-task-#{task.id}"
      assert create =~ "--label codelead.managed=true"
      assert create =~ "--label codelead.task_id=#{task.id}"
      assert create =~ "--label codelead.project_id=#{task.project_id}"
      assert create =~ "--entrypoint sleep"
      assert create =~ "-w #{context.path}"
      assert create =~ "acme/dev:1 2147483647"
      # dev bind mode: workspace root mounted at the identical path
      assert create =~ "-v #{Workspace.root()}:#{Workspace.root()}"
      assert Enum.any?(lines, &String.starts_with?(&1, "start "))
    end

    test "reuses a running container with the declared image", %{log: log} do
      use_docker("running")
      %{task: task} = container_task_setup()

      assert {:ok, _context} = DockerContainer.provision(task)
      refute Enum.any?(log_lines(log), &String.starts_with?(&1, "create "))
    end

    test "starts a stopped container instead of recreating it", %{log: log} do
      use_docker("stopped")
      %{task: task} = container_task_setup()

      assert {:ok, _context} = DockerContainer.provision(task)
      lines = log_lines(log)
      refute Enum.any?(lines, &String.starts_with?(&1, "create "))
      assert Enum.any?(lines, &String.starts_with?(&1, "start "))
    end

    test "recreates when the container was built from a different image", %{log: log} do
      use_docker("image_mismatch")
      %{task: task} = container_task_setup()

      assert {:ok, _context} = DockerContainer.provision(task)
      lines = log_lines(log)
      assert Enum.any?(lines, &String.starts_with?(&1, "rm -f codelead-task-#{task.id}"))
      assert Enum.any?(lines, &String.starts_with?(&1, "create "))
    end

    test "pulls a missing image before creating", %{log: log} do
      use_docker("no_image")
      %{task: task} = container_task_setup()

      assert {:ok, _context} = DockerContainer.provision(task)
      lines = log_lines(log)
      assert Enum.any?(lines, &String.starts_with?(&1, "pull acme/dev:1"))
      assert Enum.any?(lines, &String.starts_with?(&1, "create "))
    end

    test "a failed pull surfaces the docker error" do
      use_docker("pull_fails")
      %{task: task} = container_task_setup()

      assert {:error, {:image_pull_failed, "acme/dev:1", output}} =
               DockerContainer.provision(task)

      assert output =~ "manifest unknown"
    end

    test "an unreachable daemon is classified as such" do
      use_docker("daemon_down")
      %{task: task} = container_task_setup()

      assert {:error, {:docker_unreachable, output}} = DockerContainer.provision(task)
      assert output =~ "Cannot connect"
    end

    test "an unmounted socket is unreachable, not a pull failure" do
      use_docker("socket_missing")
      %{task: task} = container_task_setup()

      assert {:error, {:docker_unreachable, output}} = DockerContainer.provision(task)
      assert output =~ "failed to connect to the docker API"
    end

    test "an unreadable socket is a permission failure, not a pull failure" do
      use_docker("socket_denied")
      %{task: task} = container_task_setup()

      assert {:error, {:docker_permission_denied, output}} = DockerContainer.provision(task)
      assert output =~ "permission denied"
    end

    test "a failed start (image without sleep) surfaces the output" do
      use_docker("start_fails")
      %{task: task} = container_task_setup()

      assert {:error, {:container_start_failed, output}} = DockerContainer.provision(task)
      assert output =~ "sleep"
    end
  end

  describe "available?/1" do
    test "ok when the docker CLI resolves and the harness is staged" do
      use_docker("absent")
      stage_harness!()
      assert DockerContainer.available?(["claude-agent-acp"]) == :ok
    end

    test "does not require a staged binary — staging is spawn's job" do
      use_docker("absent")
      unstaged_version!()

      assert DockerContainer.available?(["claude-agent-acp"]) == :ok
    end

    test "errors cleanly when the harness version was cleared" do
      use_docker("absent")
      Application.delete_env(:code_lead, :harness_version)

      assert {:error, {:harness_not_staged, _detail}} =
               DockerContainer.available?(["claude-agent-acp"])
    end

    test "errors for commands other than the Claude harness" do
      use_docker("absent")

      assert {:error, {:container_command_unsupported, "codex"}} =
               DockerContainer.available?(["codex", "acp"])
    end

    test "errors when the docker CLI is missing" do
      Application.put_env(:code_lead, :docker_cli, ["definitely-not-docker-xyz"])
      stage_harness!()
      assert {:error, :docker_cli_not_found} = DockerContainer.available?(["claude-agent-acp"])
    end
  end

  describe "spawn/3" do
    test "execs into the container and bridges JSON-RPC stdio", %{log: log} do
      use_docker("running+happy")
      binary = stage_harness!()
      %{task: task} = container_task_setup()
      {:ok, context} = DockerContainer.provision(task)

      assert {:ok, port} = DockerContainer.spawn(context, ["claude-agent-acp"])

      Port.command(port, ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n))
      assert_receive {^port, {:data, data}}, 5_000
      assert data =~ "protocolVersion"
      Port.close(port)

      lines = log_lines(log)
      # The libc probe runs before the agent exec.
      assert Enum.any?(lines, &(String.starts_with?(&1, "exec ") and &1 =~ "ld-musl"))

      exec = Enum.find(lines, &String.starts_with?(&1, "exec -i"))
      assert exec =~ "-w #{context.path}"
      assert exec =~ "-e HOME=#{Workspace.agent_home(task.id)}"
      assert exec =~ "-e TMPDIR=#{Path.join(Workspace.agent_home(task.id), ".tmp")}"
      assert exec =~ "-e GIT_CONFIG_KEY_0=safe.directory"
      assert exec =~ "codelead-task-#{task.id} #{binary}"
    end

    test "spawn lazily recreates a missing container before exec", %{log: log} do
      use_docker("absent+happy")
      stage_harness!()
      %{task: task} = container_task_setup()
      {:ok, _} = CodeLead.Executor.LocalSubprocess.provision(task)
      task = CodeLead.Tasks.get_task!(task.id)

      context = %Context{
        type: :worktree,
        path: task.worktree_path,
        task_id: task.id,
        read_only: true,
        executor: DockerContainer
      }

      assert {:ok, port} = DockerContainer.spawn(context, ["claude-agent-acp"])
      await_agent(port)

      lines = log_lines(log)
      create_index = Enum.find_index(lines, &String.starts_with?(&1, "create "))
      exec_index = Enum.find_index(lines, &String.starts_with?(&1, "exec -i"))
      assert create_index && exec_index && create_index < exec_index
    end

    test "spawn self-stages the missing flavor before exec", %{log: log} do
      use_docker("running+happy")
      version = unstaged_version!()
      %{task: task} = container_task_setup()
      {:ok, _} = CodeLead.Executor.LocalSubprocess.provision(task)
      task = CodeLead.Tasks.get_task!(task.id)

      context = %Context{
        type: :worktree,
        path: task.worktree_path,
        task_id: task.id,
        executor: DockerContainer
      }

      assert {:ok, port} = DockerContainer.spawn(context, ["claude-agent-acp"])
      await_agent(port)

      binary = Workspace.harness_binary(version, :glibc)
      assert File.exists?(binary)

      lines = log_lines(log)
      build_index = Enum.find_index(lines, &String.starts_with?(&1, "run "))
      exec_index = Enum.find_index(lines, &String.starts_with?(&1, "exec -i"))
      assert build_index && exec_index && build_index < exec_index
      assert Enum.at(lines, exec_index) =~ binary
    end

    test "spawn surfaces a failed harness build" do
      use_docker("running+build_fails")
      unstaged_version!()
      %{task: task} = container_task_setup()
      {:ok, _} = CodeLead.Executor.LocalSubprocess.provision(task)
      task = CodeLead.Tasks.get_task!(task.id)

      context = %Context{
        type: :worktree,
        path: task.worktree_path,
        task_id: task.id,
        executor: DockerContainer
      }

      assert {:error, {:harness_build_failed, output}} =
               DockerContainer.spawn(context, ["claude-agent-acp"])

      assert output =~ "registry"
    end

    test "spawn passes project env as -e flags", %{log: log} do
      use_docker("running+happy")
      stage_harness!()
      %{task: task, project: project} = container_task_setup()
      {:ok, _} = CodeLead.Projects.put_env(project.id, "GREETING", "hello")
      {:ok, context} = DockerContainer.provision(CodeLead.Tasks.get_task!(task.id))

      {:ok, port} = DockerContainer.spawn(context, ["claude-agent-acp"])
      await_agent(port)

      exec = Enum.find(log_lines(log), &String.starts_with?(&1, "exec -i"))
      assert exec =~ "-e GREETING=hello"
    end

    test "unsupported command errors without touching docker", %{log: log} do
      use_docker("running")
      %{task: task} = container_task_setup()
      {:ok, context} = DockerContainer.provision(task)
      before = length(log_lines(log))

      assert {:error, {:container_command_unsupported, "codex"}} =
               DockerContainer.spawn(context, ["codex", "acp"])

      assert length(log_lines(log)) == before
    end
  end

  describe "teardown/2" do
    test "keep: true removes the container but keeps worktree and agent home", %{log: log} do
      use_docker("running")
      %{task: task} = container_task_setup()
      {:ok, context} = DockerContainer.provision(task)

      assert :ok = DockerContainer.teardown(context, keep: true)

      assert Enum.any?(log_lines(log), &String.starts_with?(&1, "rm -f codelead-task-#{task.id}"))
      assert File.dir?(context.path)
      assert File.dir?(Workspace.agent_home(task.id))
    end

    test "keep: false removes container, agent home, worktree and branch", %{log: log} do
      use_docker("running")
      %{task: task} = container_task_setup()
      {:ok, context} = DockerContainer.provision(task)

      assert :ok = DockerContainer.teardown(context, keep: false)

      assert Enum.any?(log_lines(log), &String.starts_with?(&1, "rm -f codelead-task-#{task.id}"))
      refute File.dir?(Workspace.agent_home(task.id))
      refute File.dir?(context.path)
    end
  end

  describe "preview port publishing" do
    test "a declared preview port is published on loopback with an ephemeral host port", %{
      log: log
    } do
      use_docker("absent")
      %{task: task} = container_task_setup(%{preview_port: 5173})

      assert {:ok, _context} = DockerContainer.provision(task)

      create = Enum.find(log_lines(log), &String.starts_with?(&1, "create "))
      assert create =~ "-p 127.0.0.1:0:5173"
    end

    test "no declared port publishes nothing", %{log: log} do
      use_docker("absent")
      %{task: task} = container_task_setup()

      assert {:ok, _context} = DockerContainer.provision(task)

      create = Enum.find(log_lines(log), &String.starts_with?(&1, "create "))
      refute create =~ "-p "
    end

    test "a running container missing the declared binding is recreated", %{log: log} do
      use_docker("running")
      %{task: task} = container_task_setup(%{preview_port: 5173})

      assert {:ok, _context} = DockerContainer.provision(task)

      lines = log_lines(log)
      assert Enum.any?(lines, &String.starts_with?(&1, "rm -f codelead-task-#{task.id}"))
      assert Enum.find(lines, &String.starts_with?(&1, "create ")) =~ "-p 127.0.0.1:0:5173"
    end

    test "a running container with the binding is reused", %{log: log} do
      use_docker("running_published")
      System.put_env("FAKE_DOCKER_PREVIEW_PORT", "5173")
      on_exit(fn -> System.delete_env("FAKE_DOCKER_PREVIEW_PORT") end)

      %{task: task} = container_task_setup(%{preview_port: 5173})

      assert {:ok, _context} = DockerContainer.provision(task)
      refute Enum.any?(log_lines(log), &String.starts_with?(&1, "create "))
    end

    test "a binding on a stale publish ip is recreated on the current one", %{log: log} do
      use_docker("running_published")
      System.put_env("FAKE_DOCKER_PREVIEW_PORT", "5173")
      Application.put_env(:code_lead, :preview_publish_ip, "172.17.0.1")

      on_exit(fn ->
        System.delete_env("FAKE_DOCKER_PREVIEW_PORT")
        Application.delete_env(:code_lead, :preview_publish_ip)
      end)

      %{task: task} = container_task_setup(%{preview_port: 5173})

      assert {:ok, _context} = DockerContainer.provision(task)

      lines = log_lines(log)
      assert Enum.any?(lines, &String.starts_with?(&1, "rm -f codelead-task-#{task.id}"))
      assert Enum.find(lines, &String.starts_with?(&1, "create ")) =~ "-p 172.17.0.1:0:5173"
    end

    test "a live runner blocks the recreate — the agent's exec must survive", %{log: log} do
      use_docker("running")
      %{task: task} = container_task_setup(%{preview_port: 5173})

      {:ok, _owner} = Registry.register(CodeLead.Runtime.Registry, task.id, nil)

      assert {:ok, _context} = DockerContainer.provision(task)

      lines = log_lines(log)
      refute Enum.any?(lines, &String.starts_with?(&1, "rm -f"))
      refute Enum.any?(lines, &String.starts_with?(&1, "create "))
    end
  end

  describe "ensure_for_task/1" do
    test "recreates an externally removed container from the task id alone", %{log: log} do
      use_docker("absent")
      %{task: task} = container_task_setup()

      assert {:ok, name} = DockerContainer.ensure_for_task(task.id)

      assert name == "codelead-task-#{task.id}"
      assert Enum.any?(log_lines(log), &String.starts_with?(&1, "create "))
    end
  end

  describe "diagnose/1" do
    test "reports external removal when the container is absent" do
      use_docker("absent")
      assert {:ok, detail} = DockerContainer.diagnose(123)
      assert detail =~ "removed externally"
    end

    test "reports an exited container" do
      use_docker("stopped")
      assert {:ok, detail} = DockerContainer.diagnose(123)
      assert detail =~ "exited"
    end

    test "stays silent when the container is running" do
      use_docker("running")
      assert DockerContainer.diagnose(123) == :none
    end

    test "stays silent when docker is unreachable" do
      use_docker("daemon_down")
      assert DockerContainer.diagnose(123) == :none
    end
  end
end
