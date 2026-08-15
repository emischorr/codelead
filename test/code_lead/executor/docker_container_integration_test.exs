defmodule CodeLead.Executor.DockerContainerIntegrationTest do
  @moduledoc """
  Drives the container executor against a **real** Docker daemon —
  excluded by default, run with `mix test --only docker`.

  The "harness" is a shell wrapper that execs the fake ACP agent from
  the mounted workspace, so the test proves the full mechanism — labeled
  create/start, the workspace mount at identical paths, the
  `docker exec -i` JSON-RPC bridge, teardown — without any API keys.
  The real-harness toolchain loop stays a manual dev check
  (docs/configuration.md).
  """

  # async: false — real containers, global config swaps.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor.DockerCli
  alias CodeLead.Executor.DockerContainer
  alias CodeLead.Workspace

  @moduletag :docker
  @moduletag timeout: 120_000

  # Small, multi-arch, ships `sleep` (BusyBox) and elixir for the fake agent.
  @image "elixir:1.18-alpine"

  setup do
    case DockerCli.run(["info", "--format", "{{.ServerVersion}}"]) do
      {:ok, _version} -> :ok
      {:error, reason} -> flunk("docker is unavailable: #{inspect(reason)}")
    end

    original_version = Application.get_env(:code_lead, :harness_version)
    Application.put_env(:code_lead, :harness_version, "integration-test")
    on_exit(fn -> Application.put_env(:code_lead, :harness_version, original_version) end)

    # Stage the wrapper "harness" plus the fake agent inside the
    # workspace, which the container sees at the identical path.
    fake_agent_src = Path.expand("../../support/fake_acp_agent.exs", __DIR__)
    fake_agent = Path.join(Workspace.root(), "fake-agent/fake_acp_agent.exs")
    File.mkdir_p!(Path.dirname(fake_agent))
    File.cp!(fake_agent_src, fake_agent)

    # elixir:1.18-alpine probes as musl; the wrapper is a sh script, so
    # the flavor only matters for path resolution. The bun sibling marks
    # the runtime dir complete so ensure_staged short-circuits instead
    # of really staging.
    binary = Workspace.harness_binary("integration-test", :musl)
    File.mkdir_p!(Path.dirname(binary))
    File.write!(binary, "#!/bin/sh\nexec elixir #{fake_agent} happy\n")
    File.chmod!(binary, 0o755)
    File.write!(Path.join(Path.dirname(binary), "bun"), "marker")

    :ok
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

    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      task_fixture(project.id, %{
        title: "Real container",
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: executor.id,
        execution_env: :container
      })

    on_exit(fn -> DockerCli.run(["rm", "-f", DockerContainer.container_name(task.id)]) end)
    task
  end

  test "provisions, execs the bridged agent in-container, and tears down" do
    task = container_task()

    assert {:ok, context} = DockerContainer.provision(task)
    name = DockerContainer.container_name(task.id)

    {:ok, labels} =
      DockerCli.run(["inspect", "--format", ~s({{.Config.Labels}}), name])

    assert labels =~ "codelead.managed:true"
    assert labels =~ "codelead.task_id:#{task.id}"

    # The worktree is visible in-container at the identical path.
    {:ok, listing} = DockerCli.run(["exec", name, "ls", context.path])
    assert listing =~ "README.md"

    # The exec bridge speaks JSON-RPC to the wrapped agent.
    assert {:ok, port} = DockerContainer.spawn(context, ["claude-agent-acp"])
    Port.command(port, ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n))
    assert_receive {^port, {:data, data}}, 60_000
    assert data =~ "protocolVersion"
    Port.close(port)

    # Full teardown removes the container along with worktree and home.
    assert :ok = DockerContainer.teardown(context, keep: false)
    assert {:error, {:docker, _status, _out}} = DockerCli.run(["inspect", name])
    refute File.dir?(context.path)
    refute File.dir?(Workspace.agent_home(task.id))
  end
end
