defmodule CodeLead.Scheduler.Gates.CapacityGate do
  @moduledoc """
  Holds a task once `:max_concurrent_runs` runners are live.

  The check counts live *executor* registrations — advisory runs
  (surveys, reviewers) never eat a slot — so two simultaneous
  dispatches can race past it briefly. Acceptable on a single node:
  the cap protects small servers, it is not a hard isolation boundary.
  """

  @behaviour CodeLead.Scheduler.Gate

  alias CodeLead.Runtime.LiveRuns
  alias CodeLead.Tasks.Task

  @impl CodeLead.Scheduler.Gate
  def check(%Task{}) do
    max_runs = Application.fetch_env!(:code_lead, :max_concurrent_runs)

    if LiveRuns.executor_count() >= max_runs do
      {:hold, :capacity}
    else
      :ok
    end
  end
end
