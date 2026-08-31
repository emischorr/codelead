defmodule CodeLead.Runtime.LiveRunsTest do
  # async: true — the registry is app-global, but every key here is
  # scoped to unique task ids generated per test.
  use ExUnit.Case, async: true

  alias CodeLead.Runtime.LiveRuns

  defp unique_task_id, do: System.unique_integer([:positive, :monotonic]) + 1_000_000

  # Registers under the given key from a supervised child and blocks
  # until told to stop, mirroring how advisory runs hold their slot.
  defp start_registered!(task_id, kind, extra \\ %{}) do
    test_pid = self()

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Elixir.Task,
           fn ->
             result = LiveRuns.register(task_id, kind, extra)
             send(test_pid, {:registered, self(), result})

             receive do
               :advisory_cancel -> :ok
             end
           end},
          id: make_ref(),
          restart: :temporary
        )
      )

    assert_receive {:registered, ^pid, :ok}
    pid
  end

  # Registry entry cleanup after a DOWN is asynchronous; draining the
  # partition process's queue makes it observable without sleeping.
  defp sync_registry do
    _ = :sys.get_state(CodeLead.Runtime.Registry)
    :ok
  end

  test "one planner per task: the key refuses a second registration" do
    task_id = unique_task_id()
    start_registered!(task_id, :plan)

    assert LiveRuns.register(task_id, :plan) == {:error, :already_running}
    assert LiveRuns.planner_running?(task_id)
  end

  test "one run per reviewer agent, but different reviewers coexist" do
    task_id = unique_task_id()
    start_registered!(task_id, {:review, 1})
    start_registered!(task_id, {:review, 2})

    assert LiveRuns.register(task_id, {:review, 1}) == {:error, :already_running}
    assert length(LiveRuns.list(task_id)) == 2
  end

  test "executor selects see only :execute keys across mixed shapes" do
    task_a = unique_task_id()
    task_b = unique_task_id()

    start_registered!(task_a, :plan)
    start_registered!(task_a, {:review, 7})

    baseline = LiveRuns.executor_count()

    {:ok, _} = Registry.register(CodeLead.Runtime.Registry, {task_b, :execute}, %{})

    assert LiveRuns.executor_count() == baseline + 1
    assert task_b in LiveRuns.executor_task_ids()
    refute task_a in LiveRuns.executor_task_ids()
    assert task_a in LiveRuns.surveying_task_ids()
    refute task_b in LiveRuns.surveying_task_ids()
    assert {_pid, %{}} = LiveRuns.lookup(task_b, :execute)
  end

  test "lookup returns pid and meta for the planner" do
    task_id = unique_task_id()
    pid = start_registered!(task_id, :plan, %{agent_id: 3, agent_name: "Scout"})

    assert {^pid, meta} = LiveRuns.lookup(task_id, :plan)
    assert meta.kind == :plan
    assert meta.agent_id == 3
    assert meta.agent_name == "Scout"
    assert %DateTime{} = meta.started_at
  end

  test "a killed run disappears from the registry" do
    task_id = unique_task_id()
    pid = start_registered!(task_id, :plan)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    sync_registry()
    refute LiveRuns.planner_running?(task_id)
    assert LiveRuns.list(task_id) == []
  end

  test "cancel_advisory stops every advisory run on the task and waits them out" do
    task_id = unique_task_id()
    other_task = unique_task_id()

    planner = start_registered!(task_id, :plan)
    reviewer = start_registered!(task_id, {:review, 5})
    bystander = start_registered!(other_task, :plan)

    planner_ref = Process.monitor(planner)
    reviewer_ref = Process.monitor(reviewer)

    assert LiveRuns.cancel_advisory(task_id) == :ok

    # cancel_advisory returns only after the runs are down
    assert_received {:DOWN, ^planner_ref, :process, ^planner, _reason}
    assert_received {:DOWN, ^reviewer_ref, :process, ^reviewer, _reason}

    sync_registry()
    assert LiveRuns.list(task_id) == []
    assert Process.alive?(bystander)
    assert LiveRuns.planner_running?(other_task)
  end

  test "cancel_advisory with nothing live is a no-op" do
    assert LiveRuns.cancel_advisory(unique_task_id()) == :ok
  end
end
