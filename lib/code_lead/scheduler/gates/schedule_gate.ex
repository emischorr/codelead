defmodule CodeLead.Scheduler.Gates.ScheduleGate do
  @moduledoc """
  Holds a task until its `scheduled_at` arrives.

  A time already in the past passes and dispatches now — the schedule
  is a "not before" bound, not an appointment to be missed, so a user
  who picks a past time gets the least surprising outcome rather than
  an error.

  This gate runs *first*: before the time arrives, the truthful reason
  the task is waiting is the clock, so that is what the badge should
  say. Budget is dynamic and can change before then anyway, which is
  why checking it at dispatch time is both correct and enough.
  """

  @behaviour CodeLead.Scheduler.Gate

  alias CodeLead.Tasks.Task

  @impl CodeLead.Scheduler.Gate
  def check(%Task{scheduled_at: scheduled_at} = task) do
    if Task.scheduled?(task), do: {:hold, {:scheduled, scheduled_at}}, else: :ok
  end
end
