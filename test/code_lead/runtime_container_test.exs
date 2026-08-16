defmodule CodeLead.RuntimeContainerTest do
  # async: false — swaps the :docker_cli and :harness_version config and
  # env vars the fake docker script reads.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor
  alias CodeLead.Executor.DockerContainer
  alias CodeLead.Executor.LocalSubprocess
  alias CodeLead.Runtime
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Runtime.TaskRunner
  alias CodeLead.Tasks
  alias CodeLead.Workspace

  @fake_docker Path.expand("../support/fake_docker.sh", __DIR__)
  @image "acme/dev:1"

  setup do
    original = Application.get_env(:code_lead, :docker_cli)
    original_version = Application.get_env(:code_lead, :harness_version)
    original_source = Application.get_env(:code_lead, :harness_source)
    log = Path.join(System.tmp_dir!(), "fake_docker_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_DOCKER_LOG", log)
    System.put_env("FAKE_DOCKER_IMAGE", @image)

    on_exit(fn ->
      Application.put_env(:code_lead, :docker_cli, original)
      Application.put_env(:code_lead, :harness_version, original_version)
      Application.put_env(:code_lead, :harness_source, original_source)
      System.delete_env("FAKE_DOCKER_LOG")
      System.delete_env("FAKE_DOCKER_IMAGE")
      File.rm(log)
    end)

    %{log: log}
  end

  defp use_docker(scenario) do
    Application.put_env(:code_lead, :docker_cli, ["sh", @fake_docker, scenario])
  end

  # The fake probe answers glibc by default, so the glibc flavor is the
  # one a run resolves. Wrapper plus the bun sibling marks a staged
  # runtime as complete.
  defp stage_harness! do
    Application.put_env(:code_lead, :harness_version, "test")
    binary = Workspace.harness_binary("test", :glibc)
    File.mkdir_p!(Path.dirname(binary))
    File.write!(binary, "#!/bin/sh\n")
    File.write!(Path.join(Path.dirname(binary), "bun"), "a-bun")
  end

  defp container_task do
    project = project_fixture()
    git_url = create_origin!()

    repository =
      repository_fixture(project.id, %{
        git_url: git_url,
        default_branch: "main",
        env_kind: :image,
        image_ref: @image
      })

    agent =
      agent_fixture(%{driver: :acp, harness: :claude_code, work_type: :code, roles: [:execute]})

    task =
      task_fixture(project.id, %{
        title: "Container run",
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: agent.id,
        execution_env: :container,
        description: "Do it."
      })

    %{project: project, repository: repository, agent: agent, task: task}
  end

  defp subscribe(task) do
    Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")
  end

  defp await_runner_down(task_id) do
    case RunSupervisor.whereis(task_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
        :ok
    end
  end

  defp log_lines(log) do
    case File.read(log) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _} -> []
    end
  end

  describe "Executor.for_task/1" do
    test "routes only container repo tasks to DockerContainer" do
      assert Executor.for_task(%Tasks.Task{target: :repo, execution_env: :container}) ==
               DockerContainer

      assert Executor.for_task(%Tasks.Task{target: :repo, execution_env: :local}) ==
               LocalSubprocess

      # A folder target is structurally local, whatever the field says.
      assert Executor.for_task(%Tasks.Task{target: :folder, execution_env: :container}) ==
               LocalSubprocess

      assert Executor.for_task(%Tasks.Task{target: :folder, execution_env: :local}) ==
               LocalSubprocess
    end
  end

  describe "the container run loop" do
    test "runs the agent through docker exec and lands in Review", %{log: log} do
      use_docker("absent+happy")
      stage_harness!()
      %{task: task} = container_task()
      subscribe(task)

      assert {:ok, _task} = Runtime.start_task(task)

      assert_receive {:task_event, _id, {:run_started, _agent}}, 15_000
      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.state == :review
      assert task.acp_session_id == "fake-sess-happy"

      lines = log_lines(log)
      assert Enum.any?(lines, &String.starts_with?(&1, "create --name codelead-task-#{task.id}"))
      exec = Enum.find(lines, &String.starts_with?(&1, "exec -i"))
      assert exec =~ "-w #{task.worktree_path}"
      assert exec =~ "-e HOME=#{Workspace.agent_home(task.id)}"
    end

    test "cancel removes the container but keeps worktree and agent home", %{log: log} do
      # The permission scenario blocks awaiting an answer, holding the
      # run in :executing so cancel has something to cancel.
      use_docker("absent+permission")
      stage_harness!()
      %{task: task} = container_task()
      subscribe(task)

      assert {:ok, _task} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_started, _agent}}, 15_000

      task = Tasks.get_task!(task.id)
      assert {:ok, cancelled} = Runtime.cancel_task(task)
      await_runner_down(task.id)

      assert cancelled.state == :planning
      assert Enum.any?(log_lines(log), &String.starts_with?(&1, "rm -f codelead-task-#{task.id}"))
      assert File.dir?(task.worktree_path)
      assert File.dir?(Workspace.agent_home(task.id))
    end

    test "send back to planning removes container, agent home, and worktree", %{log: log} do
      use_docker("absent+happy")
      stage_harness!()
      %{task: task} = container_task()
      subscribe(task)

      assert {:ok, _task} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.state == :review
      worktree = task.worktree_path

      assert {:ok, task} = Runtime.send_back_to_planning(task)

      assert task.worktree_path == nil
      assert task.acp_session_id == nil
      assert Enum.any?(log_lines(log), &String.starts_with?(&1, "rm -f codelead-task-#{task.id}"))
      refute File.dir?(worktree)
      refute File.dir?(Workspace.agent_home(task.id))
    end

    test "a mid-run container death fails the run with the diagnosed detail" do
      use_docker("absent+exec_dies")
      stage_harness!()
      %{task: task} = container_task()
      subscribe(task)

      assert {:ok, _task} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_failed, detail}}, 15_000
      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.run_state == :failed
      assert task.attention.type == :run_failed
      assert detail =~ "removed externally"

      # Retry re-provisions from scratch — same worktree, fresh container.
      assert {:ok, _task} = Runtime.retry_task(task)
      assert_receive {:task_event, _id, {:run_failed, _detail}}, 15_000
      await_runner_down(task.id)
    end

    test "self-stages the harness before the first container run", %{log: log} do
      use_docker("absent+happy")
      version = "0.0.#{System.unique_integer([:positive])}"
      Application.put_env(:code_lead, :harness_version, version)
      Application.put_env(:code_lead, :harness_source, "/definitely/not/here")
      %{task: task} = container_task()
      subscribe(task)

      assert {:ok, _task} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_completed, _result}}, 15_000
      await_runner_down(task.id)

      assert Tasks.get_task!(task.id).state == :review
      assert File.exists?(Workspace.harness_binary(version, :glibc))

      # Staging happens at spawn now: provision's create precedes the
      # build, which precedes the agent exec.
      lines = log_lines(log)
      create_index = Enum.find_index(lines, &String.starts_with?(&1, "create "))
      build_index = Enum.find_index(lines, &String.starts_with?(&1, "run "))
      exec_index = Enum.find_index(lines, &String.starts_with?(&1, "exec -i"))
      assert create_index && build_index && exec_index
      assert create_index < build_index and build_index < exec_index
    end

    test "a failed image pull fails dispatch with the docker error surfaced" do
      use_docker("pull_fails")
      stage_harness!()
      %{task: task} = container_task()
      subscribe(task)

      assert {:ok, _task} = Runtime.start_task(task)
      assert_receive {:task_event, _id, {:run_failed, detail}}, 15_000
      await_runner_down(task.id)

      task = Tasks.get_task!(task.id)
      assert task.run_state == :failed
      assert detail =~ "could not pull the container image"
      assert detail =~ "manifest unknown"
    end
  end

  describe "dispatch_error/1 rendering" do
    test "routes a missing declaration to repository settings" do
      message = TaskRunner.dispatch_error({:provision, {:missing_execution_env, "my-app"}})
      assert message =~ "declares no container image"
      assert message =~ "Settings → Project → Repositories"
    end

    test "explains an unreachable daemon" do
      assert TaskRunner.dispatch_error({:provision, {:docker_unreachable, "boom"}}) =~
               "/var/run/docker.sock"
    end

    test "explains a socket the app user cannot read" do
      assert TaskRunner.dispatch_error({:provision, {:docker_permission_denied, "boom"}}) =~
               "group_add"
    end

    test "explains an unstaged harness" do
      assert TaskRunner.dispatch_error({:harness_not_staged, "/x/claude-agent-acp"}) =~
               "HARNESS_VERSION"
    end

    test "explains a failed harness build with the manual override" do
      message = TaskRunner.dispatch_error({:harness_build_failed, "registry timeout"})
      assert message =~ "registry timeout"
      assert message =~ "HARNESS_SOURCE"
    end

    test "explains the sleep-entrypoint requirement on start failure" do
      assert TaskRunner.dispatch_error({:provision, {:container_start_failed, "no sleep"}}) =~
               "`sleep` binary"
    end

    test "names the Claude-only limitation for other harness commands" do
      assert TaskRunner.dispatch_error({:container_command_unsupported, "codex"}) =~
               "Claude Code harness only"
    end
  end
end
