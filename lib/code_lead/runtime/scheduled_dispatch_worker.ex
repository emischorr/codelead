defmodule CodeLead.Runtime.ScheduledDispatchWorker do
  @moduledoc """
  Wakes a task up when its `scheduled_at` arrives and asks the
  scheduler — again — whether it may run.

  Two properties earn this module its shape:

  **It re-runs `admit?/1` rather than dispatching.** The budget and
  capacity gates therefore still apply at 2am, so an unattended run
  cannot quietly blow a limit. A hold at that point is not a failure:
  the task simply stays queued for whatever reason now applies.

  **It verifies itself instead of being cancelled.** The scheduled
  time is embedded in the job args, and the job no-ops unless the task
  still exists, still sits queued in Running, and still carries that
  exact time. Cancelling, rescheduling, running early and deleting all
  fall out of that one check — nothing has to race Oban to withdraw a
  job.

  If the server is down at T, Oban runs the job late on recovery. That
  is the MVP default; skipping a run that is more than N late is a
  later refinement.
  """

  use Oban.Worker, queue: :dispatch, max_attempts: 3

  alias CodeLead.Runtime.StageEffects
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task

  @doc """
  Enqueues the wake-up for a task held by `ScheduleGate`. Idempotent:
  re-entering the queued state for the same time does not stack jobs.

  Uniqueness covers the pending states only: a job that already fired
  and found nothing to do must not block scheduling the same task for
  the same time again later.
  """
  @spec ensure_enqueued(pos_integer(), DateTime.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def ensure_enqueued(task_id, %DateTime{} = scheduled_at) do
    %{task_id: task_id, scheduled_at: scheduled_at}
    |> new(
      scheduled_at: scheduled_at,
      unique: [
        keys: [:task_id, :scheduled_at],
        period: :infinity,
        states: [:available, :scheduled, :retryable]
      ]
    )
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id, "scheduled_at" => scheduled_at}}) do
    with {:ok, at} <- parse_scheduled_at(scheduled_at),
         %Task{} = task <- Tasks.get_task(task_id),
         true <- still_scheduled_for?(task, at) do
      StageEffects.try_dispatch(task)
      :ok
    else
      # Cancelled, rescheduled, already running, or gone. Nothing to do
      # and nothing wrong — a stale job is the expected outcome of every
      # one of those.
      _stale -> :ok
    end
  end

  defp parse_scheduled_at(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  # Args round-trip through JSON, so the embedded time comes back as a
  # string and has to be compared, never matched.
  defp still_scheduled_for?(%Task{state: :running, run_state: :queued, scheduled_at: at}, job_at)
       when not is_nil(at) do
    DateTime.compare(at, job_at) == :eq
  end

  defp still_scheduled_for?(%Task{}, _job_at), do: false
end
