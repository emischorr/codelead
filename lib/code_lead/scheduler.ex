defmodule CodeLead.Scheduler do
  @moduledoc """
  Behaviour for admitting and dispatching queued task runs. Bound to
  the task's provider connection, not global.

  `admit?/1` is an **ordered composition of gates**
  (`CodeLead.Scheduler.Gate`), not one monolithic check. Gates compose
  where impls would exclude: a run can be held by a wall clock *and*
  still be budget-enforced when that clock runs out, which a
  `Scheduled`-vs-`PassThrough` split could not express without
  duplicating the budget check.

  MVP implementation: `PassThrough` — schedule, then budget, then
  concurrency cap; dispatch immediately once all three pass. Adding
  the planned subscription-window behaviour is a `WindowGate` in that
  list, not a new impl.
  """

  alias CodeLead.Tasks.Task

  @typedoc """
  Why a task stays queued. Reasons carry data where the UI needs it:
  a hold until a known time reports that time so the badge can show it.
  """
  @type hold_reason ::
          :budget
          | :capacity
          | {:scheduled, DateTime.t()}

  @doc """
  May this queued task start now? `{:hold, reason}` keeps it queued
  (shown as a badge in the Running column).
  """
  @callback admit?(task :: Task.t()) :: :ok | {:hold, hold_reason()}

  @doc """
  Starts the run (a `TaskRunner` process).
  """
  @callback dispatch(task :: Task.t()) :: {:ok, pid()} | {:error, term()}

  @spec impl() :: module()
  def impl do
    Application.get_env(:code_lead, :scheduler, CodeLead.Scheduler.PassThrough)
  end
end
