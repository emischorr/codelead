defmodule FrontSeat.Scheduler.Gates.BudgetGate do
  @moduledoc """
  Holds a task whose project or organization has reached a token or
  cost limit.

  It matters most where nobody is watching: a scheduled run re-enters
  the gate list when its time arrives, so an unattended 2am dispatch
  is budget-checked exactly like an attended one.
  """

  @behaviour FrontSeat.Scheduler.Gate

  alias FrontSeat.Costs
  alias FrontSeat.Tasks.Task

  @impl FrontSeat.Scheduler.Gate
  def check(%Task{project_id: project_id}), do: Costs.check_budget(project_id)
end
