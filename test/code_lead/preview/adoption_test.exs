defmodule CodeLead.Preview.AdoptionTest do
  # async: false — swaps the :docker_cli config and env vars, and
  # sessions register in the app-global Preview registry.
  use CodeLead.DataCase, async: false

  import CodeLead.ProjectsFixtures
  import CodeLead.TasksFixtures

  alias CodeLead.LicenseHelpers
  alias CodeLead.Preview
  alias CodeLead.Workspace

  @fake_docker Path.expand("../../support/fake_docker.sh", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :docker_cli)
    log = Path.join(System.tmp_dir!(), "fake_docker_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_DOCKER_LOG", log)
    Application.put_env(:code_lead, :docker_cli, ["sh", @fake_docker, "running"])

    on_exit(fn ->
      Application.put_env(:code_lead, :docker_cli, original)
      System.delete_env("FAKE_DOCKER_LOG")
      System.delete_env("FAKE_DOCKER_PID_ALIVE")
      File.rm(log)
      LicenseHelpers.grant_owner!()
    end)

    %{log: log}
  end

  # A task in Review with a container context and a recorded preview pid
  # — the exact shape the boot reaper deliberately spares.
  defp review_task!(recorded_pid) do
    project = project_fixture()

    repository =
      repository_fixture(project.id, %{
        env_kind: :devcontainer,
        preview_port: 5173,
        preview_command: "sleep 300"
      })

    task =
      project.id
      |> task_fixture(%{target: :repo, repository_id: repository.id})
      |> put_context!(%{
        state: :review,
        execution_env: :container,
        worktree_path: Workspace.worktree_path(1)
      })

    if recorded_pid do
      pid_file = Path.join(Workspace.agent_home(task.id), "preview.pid")
      File.mkdir_p!(Path.dirname(pid_file))
      File.write!(pid_file, "#{recorded_pid}\n")
      on_exit(fn -> File.rm_rf(Workspace.agent_home(task.id)) end)
    end

    task
  end

  defp log_lines(log) do
    case File.read(log) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _no_log} -> []
    end
  end

  test "a live recorded pid gets a session back instead of a second server" do
    System.put_env("FAKE_DOCKER_PID_ALIVE", "1")
    task = review_task!(4242)

    assert Preview.adopt_survivors() == :ok
    assert {:ok, adopted} = fetch_session(task.id)

    # The whole point: starting a preview now re-uses the surviving
    # server rather than running preview_command a second time.
    assert Preview.ensure_session(task) == {:ok, adopted}

    on_exit(fn -> Preview.stop(task.id) end)
  end

  test "a stale recorded pid adopts nothing" do
    System.put_env("FAKE_DOCKER_PID_ALIVE", "0")
    task = review_task!(4242)

    assert Preview.adopt_survivors() == :ok
    assert Preview.status(task.id) == :stopped
  end

  test "a task with no recorded pid adopts nothing" do
    System.put_env("FAKE_DOCKER_PID_ALIVE", "1")
    task = review_task!(nil)

    assert Preview.adopt_survivors() == :ok
    assert Preview.status(task.id) == :stopped
  end

  test "stopping an adopted session signals the recorded pid", %{log: log} do
    System.put_env("FAKE_DOCKER_PID_ALIVE", "1")
    task = review_task!(4242)

    assert Preview.adopt_survivors() == :ok
    assert {:ok, adopted} = fetch_session(task.id)

    ref = Process.monitor(adopted)
    assert Preview.stop(task.id) == :ok
    assert_receive {:DOWN, ^ref, :process, ^adopted, :normal}, 2_000

    assert Enum.any?(log_lines(log), &String.contains?(&1, "kill -TERM"))
  end

  test "an adopted server that never answers the probe is signalled and forgotten" do
    System.put_env("FAKE_DOCKER_PID_ALIVE", "1")
    original = Application.get_env(:code_lead, :preview_start_timeout_ms)
    Application.put_env(:code_lead, :preview_start_timeout_ms, 50)

    on_exit(fn ->
      if original,
        do: Application.put_env(:code_lead, :preview_start_timeout_ms, original),
        else: Application.delete_env(:code_lead, :preview_start_timeout_ms)
    end)

    task = review_task!(4242)
    :ok = Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task.id}")

    assert Preview.adopt_survivors() == :ok
    assert {:ok, adopted} = fetch_session(task.id)
    ref = Process.monitor(adopted)

    # No failure panel: an adopted session has no log tail to show.
    assert_receive {:preview_state, _task_id, :stopped}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^adopted, :normal}, 2_000
    assert Preview.status(task.id) == :stopped
  end

  test "a community instance adopts nothing" do
    System.put_env("FAKE_DOCKER_PID_ALIVE", "1")
    task = review_task!(4242)
    LicenseHelpers.grant_community!()

    assert Preview.adopt_survivors() == :ok
    assert Preview.status(task.id) == :stopped
  end

  defp fetch_session(task_id) do
    case Registry.lookup(CodeLead.Preview.Registry, task_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end
