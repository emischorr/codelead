defmodule CodeLead.Scheduler.PassThrough do
  @moduledoc """
  MVP scheduler: admit unless a budget limit is reached
  (`{:hold, :budget}`) or the max-concurrent-runs cap is hit
  (`{:hold, :capacity}`); dispatch immediately.

  The capacity check counts live runner registrations — two
  simultaneous dispatches can race past it briefly. Acceptable on a
  single node; the cap protects small servers, it is not a hard
  isolation boundary.
  """

  @behaviour CodeLead.Scheduler

  alias CodeLead.Costs
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Tasks.Task

  @impl CodeLead.Scheduler
  def admit?(%Task{} = task) do
    with :ok <- Costs.check_budget(task.project_id) do
      max_runs = Application.fetch_env!(:code_lead, :max_concurrent_runs)

      if RunSupervisor.active_count() >= max_runs do
        {:hold, :capacity}
      else
        :ok
      end
    end
  end

  @impl CodeLead.Scheduler
  def dispatch(%Task{} = task) do
    RunSupervisor.start_runner(task.id)
  end
end
