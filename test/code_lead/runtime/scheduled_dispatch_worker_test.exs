defmodule CodeLead.Runtime.ScheduledDispatchWorkerTest do
  # async: false — dispatch reaches the runtime supervisor, and the
  # capacity gate reads a global concurrency cap.
  use CodeLead.DataCase, async: false
  use Oban.Testing, repo: CodeLead.Repo

  @moduletag :capture_log

  import CodeLead.TasksFixtures

  alias CodeLead.Costs
  alias CodeLead.Projects
  alias CodeLead.Runtime
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Runtime.ScheduledDispatchWorker
  alias CodeLead.Tasks

  setup do
    original_max = Application.get_env(:code_lead, :max_concurrent_runs)
    on_exit(fn -> Application.put_env(:code_lead, :max_concurrent_runs, original_max) end)
    :ok
  end

  describe "ensure_enqueued/2" do
    test "enqueues one job for the scheduled time" do
      %{task: task} = runnable_task_fixture()

      assert {:ok, _job} = ScheduledDispatchWorker.ensure_enqueued(task.id, in_an_hour())

      assert_enqueued(worker: ScheduledDispatchWorker, args: %{task_id: task.id})
    end

    test "is idempotent — re-entering the queue does not stack jobs" do
      %{task: task} = runnable_task_fixture()
      at = in_an_hour()

      assert {:ok, _job} = ScheduledDispatchWorker.ensure_enqueued(task.id, at)
      assert {:ok, _job} = ScheduledDispatchWorker.ensure_enqueued(task.id, at)

      assert length(all_enqueued(worker: ScheduledDispatchWorker)) == 1
    end
  end

  describe "perform/1 at the start time" do
    test "dispatches a task that is still queued for that time" do
      {task, at} = task_at_its_start_time()
      Tasks.subscribe_board(task.project_id)

      assert :ok = perform_job(ScheduledDispatchWorker, job_args(task, at))

      # The runner is a separate process, so wait for the state change it
      # broadcasts rather than reading the row straight back.
      assert_receive {:board_changed, _project_id, _task_id}, 5_000
      refute Tasks.get_task!(task.id).run_state == :queued

      # Let the runner finish inside the test; otherwise it touches the
      # database after the sandbox has rolled back.
      await_runner_down(task.id)
    end

    test "a scheduled run over budget is held, not dispatched" do
      {task, at} = task_at_its_start_time()
      put_over_budget(task)

      assert :ok = perform_job(ScheduledDispatchWorker, job_args(task, at))

      assert Tasks.get_task!(task.id).run_state == :queued
      assert RunSupervisor.whereis(task.id) == nil
    end

    test "a scheduled run at capacity is held, not dispatched" do
      {task, at} = task_at_its_start_time()
      Application.put_env(:code_lead, :max_concurrent_runs, 0)

      assert :ok = perform_job(ScheduledDispatchWorker, job_args(task, at))

      assert Tasks.get_task!(task.id).run_state == :queued
      assert RunSupervisor.whereis(task.id) == nil
    end
  end

  describe "perform/1 self-verification" do
    test "no-ops when the task was cancelled back to Planning" do
      {task, at} = task_at_its_start_time()
      {:ok, task} = Runtime.cancel_task(task)

      assert task.state == :planning
      assert task.scheduled_at == nil

      assert :ok = perform_job(ScheduledDispatchWorker, job_args(task, at))

      assert Tasks.get_task!(task.id).state == :planning
      assert RunSupervisor.whereis(task.id) == nil
    end

    test "no-ops when the schedule was cleared to run early" do
      {task, at} = task_at_its_start_time()
      {:ok, _task} = Tasks.clear_schedule(task)

      assert :ok = perform_job(ScheduledDispatchWorker, job_args(task, at))

      assert RunSupervisor.whereis(task.id) == nil
    end

    test "no-ops when the task now carries a different start time" do
      {task, at} = task_at_its_start_time()
      # Also in the past, so only the mismatch can explain the no-op.
      {:ok, task} = reschedule(task, DateTime.add(at, -60))

      assert :ok = perform_job(ScheduledDispatchWorker, job_args(task, at))

      assert Tasks.get_task!(task.id).run_state == :queued
      assert RunSupervisor.whereis(task.id) == nil
    end

    test "no-ops when the run already moved past queued" do
      {task, at} = task_at_its_start_time()
      {:ok, _task} = Tasks.begin_dispatch(task)

      assert :ok = perform_job(ScheduledDispatchWorker, job_args(task, at))

      assert RunSupervisor.whereis(task.id) == nil
    end

    test "no-ops when the task is gone" do
      {task, at} = task_at_its_start_time()
      Repo.delete!(task)

      assert :ok = perform_job(ScheduledDispatchWorker, job_args(task, at))
    end
  end

  ## Helpers

  defp in_an_hour, do: DateTime.add(DateTime.utc_now(:second), 3600)

  defp await_runner_down(task_id) do
    case RunSupervisor.whereis(task_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end

  # A task queued in Running whose start time has just arrived: scheduled
  # for the future so it genuinely queues, then wound forward so the
  # schedule gate passes and the *other* gates decide the outcome.
  defp task_at_its_start_time do
    %{task: task} = runnable_task_fixture()

    {:ok, task} = Runtime.start_task(task, scheduled_at: in_an_hour())
    assert task.run_state == :queued

    at = DateTime.add(DateTime.utc_now(:second), -1)
    {:ok, task} = reschedule(task, at)

    {task, at}
  end

  defp reschedule(task, at) do
    task
    |> Ecto.Changeset.change(scheduled_at: at)
    |> Repo.update()
  end

  defp job_args(task, at) do
    %{task_id: task.id, scheduled_at: DateTime.to_iso8601(at)}
  end

  defp put_over_budget(task) do
    {:ok, _project} =
      task.project_id
      |> Projects.get_project!()
      |> Projects.update_project(%{budget_limit_cents: 5})

    {:ok, _run} =
      Costs.record_run(%{
        task_id: task.id,
        status: :ok,
        started_at: DateTime.utc_now(:second),
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2, cost_cents: 10}
      })
  end
end
