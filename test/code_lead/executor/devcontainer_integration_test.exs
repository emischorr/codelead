defmodule CodeLead.Executor.DevcontainerIntegrationTest do
  @moduledoc """
  Drives the devcontainer executor against a **real** Docker daemon and
  a **real** devcontainer CLI — excluded by default, run with
  `mix test --only devcontainer` (needs `npm i -g @devcontainers/cli`).

  The "harness" is a shell wrapper that execs the fake ACP agent from
  the mounted workspace, so the test proves the full mechanism —
  `devcontainer up` with id-labels and the coincident workspace mount,
  the `docker exec -i` JSON-RPC bridge, label-based teardown — without
  any API keys. The real-harness toolchain loop stays a manual dev
  check (docs/configuration.md).
  """

  # async: false — real containers, global config swaps.
  use CodeLead.DataCase, async: false

  import CodeLead.AgentsFixtures
  import CodeLead.GitHelpers
  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.Executor.Devcontainer
  alias CodeLead.Executor.DevcontainerCli
  alias CodeLead.Executor.DockerCli
  alias CodeLead.Preview
  alias CodeLead.PreviewGateway.PathProxy
  alias CodeLead.PreviewGateway.Relay
  alias CodeLead.Workspace

  @moduletag :devcontainer
  @moduletag timeout: 300_000

  # Small, multi-arch, ships elixir for the fake agent.
  @image "elixir:1.18-alpine"

  setup do
    case DockerCli.run(["info", "--format", "{{.ServerVersion}}"]) do
      {:ok, _version} -> :ok
      {:error, reason} -> flunk("docker is unavailable: #{inspect(reason)}")
    end

    unless DevcontainerCli.available?() do
      flunk("the devcontainer CLI is unavailable — npm i -g @devcontainers/cli")
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

  defp container_task(repository_attrs \\ %{}, image \\ @image) do
    project = project_fixture()
    git_url = create_origin!()

    commit_on_origin!(
      git_url,
      ".devcontainer/devcontainer.json",
      ~s({"image": "#{image}"})
    )

    repository =
      repository_fixture(
        project.id,
        Map.merge(
          %{git_url: git_url, default_branch: "main", env_kind: :devcontainer},
          repository_attrs
        )
      )

    executor = agent_fixture(%{roles: [:execute], work_type: :code})

    task =
      task_fixture(project.id, %{
        title: "Real devcontainer",
        work_type: :code,
        target: :repo,
        repository_id: repository.id,
        agent_id: executor.id,
        execution_env: :container
      })

    on_exit(fn ->
      Preview.stop(task.id)
      Relay.remove(task.id)
      Devcontainer.remove_environment(task.id)
    end)

    task
  end

  test "provisions via devcontainer up, execs the bridged agent, and tears down by label" do
    task = container_task()

    assert {:ok, context} = Devcontainer.provision(task)
    assert {:ok, container_id} = Devcontainer.container_for_task(task.id)
    assert container_id == context.exec_ref

    {:ok, labels} =
      DockerCli.run(["inspect", "--format", ~s({{.Config.Labels}}), container_id])

    assert labels =~ "codelead.managed:true"
    assert labels =~ "codelead.task_container:true"
    assert labels =~ "codelead.task_id:#{task.id}"

    # The worktree is visible in-container at the identical path.
    {:ok, listing} = DockerCli.run(["exec", container_id, "ls", context.path])
    assert listing =~ "README.md"

    # The worktree's gitdir (in the base clone) resolves through the
    # coincident mount — the invariant in-container git depends on.
    {:ok, gitdir_check} =
      DockerCli.run(
        ["exec", container_id, "sh", "-c"] ++
          [~s{test -d "$(sed 's/^gitdir: //' #{context.path}/.git)" && echo resolved}]
      )

    assert gitdir_check =~ "resolved"

    # The exec bridge speaks JSON-RPC to the wrapped agent.
    assert {:ok, port} = Devcontainer.spawn(context, ["claude-agent-acp"])
    Port.command(port, ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n))
    assert_receive {^port, {:data, data}}, 60_000
    assert data =~ "protocolVersion"
    Port.close(port)

    # Full teardown removes the environment along with worktree and home.
    assert :ok = Devcontainer.teardown(context, keep: false)
    assert Devcontainer.container_for_task(task.id) == :absent
    refute File.dir?(context.path)
    refute File.dir?(Workspace.agent_home(task.id))
  end

  test "one-click preview: relay + preview command answer through the gateway" do
    # python's stdlib server serves the worktree in the foreground on
    # the declared port — the whole chain is real: session exec into the
    # devcontainer, socat relay on its network, TCP readiness probe
    # through the gateway upstream.
    task =
      container_task(
        %{preview_port: 8199, preview_command: "python3 -m http.server 8199"},
        "python:3-alpine"
      )

    assert {:ok, context} = Devcontainer.provision(task)
    task = put_context!(task, %{worktree_path: context.path, execution_env: :container})

    :ok = Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")

    assert {:ok, _pid} = Preview.ensure_session(task)
    assert_receive {:preview_state, _id, :starting}, 5_000
    assert_receive {:preview_state, _id, :ready}, 60_000

    # The proxy's own resolution path reaches the served worktree.
    assert {:ok, %{host: host, port: port}} = PathProxy.upstream_for(task)
    {:ok, socket} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET /README.md HTTP/1.0\r\n\r\n")
    {:ok, response} = :gen_tcp.recv(socket, 0, 10_000)
    :gen_tcp.close(socket)
    assert response =~ "200 OK"

    # Stop kills the server inside the container by its recorded pid.
    assert Preview.stop(task.id) == :ok
    assert_receive {:preview_state, _id, :stopped}, 5_000
    assert Preview.status(task.id) == :stopped
  end
end
