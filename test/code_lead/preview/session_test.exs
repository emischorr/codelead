defmodule CodeLead.Preview.SessionTest do
  # async: false — overrides the preview timeout config keys.
  use ExUnit.Case, async: false

  alias CodeLead.Preview.Session

  setup do
    on_exit(fn ->
      Application.delete_env(:code_lead, :preview_idle_ms)
      Application.delete_env(:code_lead, :preview_start_timeout_ms)
    end)

    task_id = System.unique_integer([:positive])
    :ok = Phoenix.PubSub.subscribe(CodeLead.PubSub, "task:#{task_id}")
    %{task_id: task_id}
  end

  defp sh, do: System.find_executable("sh")

  defp long_running_opener do
    fn ->
      Port.open({:spawn_executable, sh()}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: ["-c", "sleep 30"]
      ])
    end
  end

  defp start_arg(task_id, overrides) do
    Map.merge(
      %{
        task_id: task_id,
        port_opener: long_running_opener(),
        stopper: fn _port -> :ok end,
        probe: fn -> :waiting end
      },
      overrides
    )
  end

  test "broadcasts :starting, then :ready once the probe answers", %{task_id: task_id} do
    start_supervised!({Session, start_arg(task_id, %{probe: fn -> :ready end})})

    assert_receive {:preview_state, ^task_id, :starting}, 2_000
    assert_receive {:preview_state, ^task_id, :ready}, 3_000
  end

  test "fails with the log tail when the command exits before readiness", %{task_id: task_id} do
    opener = fn ->
      Port.open({:spawn_executable, sh()}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: ["-c", "echo boom; exit 1"]
      ])
    end

    pid = start_supervised!({Session, start_arg(task_id, %{port_opener: opener})})
    ref = Process.monitor(pid)

    assert_receive {:preview_state, ^task_id, {:failed, tail}}, 3_000
    assert tail =~ "boom"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "fails when the start timeout passes without readiness", %{task_id: task_id} do
    Application.put_env(:code_lead, :preview_start_timeout_ms, 50)
    parent = self()

    pid =
      start_supervised!(
        {Session, start_arg(task_id, %{stopper: fn _port -> send(parent, :stopper_ran) end})}
      )

    ref = Process.monitor(pid)

    assert_receive {:preview_state, ^task_id, {:failed, _tail}}, 3_000
    assert_receive :stopper_ran, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "a server exit after readiness broadcasts :stopped", %{task_id: task_id} do
    opener = fn ->
      Port.open({:spawn_executable, sh()}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        # Long enough that the 1s probe interval marks the session ready
        # first, short enough that the exit follows promptly.
        args: ["-c", "sleep 2"]
      ])
    end

    start_supervised!(
      {Session, start_arg(task_id, %{port_opener: opener, probe: fn -> :ready end})}
    )

    assert_receive {:preview_state, ^task_id, :ready}, 3_000
    assert_receive {:preview_state, ^task_id, :stopped}, 5_000
  end

  test "stop runs the stopper and broadcasts :stopped", %{task_id: task_id} do
    parent = self()

    pid =
      start_supervised!(
        {Session,
         start_arg(task_id, %{
           probe: fn -> :ready end,
           stopper: fn _port -> send(parent, :stopper_ran) end
         })}
      )

    ref = Process.monitor(pid)
    assert_receive {:preview_state, ^task_id, :ready}, 3_000

    assert GenServer.call(pid, :stop) == :ok
    assert_receive :stopper_ran, 1_000
    assert_receive {:preview_state, ^task_id, :stopped}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "stops after the idle timeout with no viewers", %{task_id: task_id} do
    Application.put_env(:code_lead, :preview_idle_ms, 50)

    pid = start_supervised!({Session, start_arg(task_id, %{probe: fn -> :ready end})})
    ref = Process.monitor(pid)

    assert_receive {:preview_state, ^task_id, :stopped}, 3_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "an attached viewer holds the session past the idle timeout", %{task_id: task_id} do
    Application.put_env(:code_lead, :preview_idle_ms, 50)

    pid = start_supervised!({Session, start_arg(task_id, %{probe: fn -> :ready end})})
    assert GenServer.call(pid, {:attach, self()}) == :ok

    assert_receive {:preview_state, ^task_id, :ready}, 3_000
    refute_receive {:preview_state, ^task_id, :stopped}, 300
    assert GenServer.call(pid, :status) == :ready
  end
end
