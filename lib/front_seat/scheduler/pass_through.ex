defmodule FrontSeat.Scheduler.PassThrough do
  @moduledoc """
  MVP scheduler: run the gate list in order, dispatch if every gate
  passes, otherwise report the first hold.

  The order is the contract. `ScheduleGate` comes first so a task
  waiting on its start time says so rather than reporting whatever
  the budget happened to look like hours before it runs.
  """

  @behaviour FrontSeat.Scheduler

  alias FrontSeat.Runtime.RunSupervisor
  alias FrontSeat.Scheduler.Gates.BudgetGate
  alias FrontSeat.Scheduler.Gates.CapacityGate
  alias FrontSeat.Scheduler.Gates.ScheduleGate
  alias FrontSeat.Tasks.Task

  # A future `WindowGate` (hold for a subscription token-window reset)
  # belongs in this list, after ScheduleGate — nowhere else.
  @gates [ScheduleGate, BudgetGate, CapacityGate]

  @impl FrontSeat.Scheduler
  def admit?(%Task{} = task) do
    Enum.reduce_while(@gates, :ok, fn gate, :ok ->
      case gate.check(task) do
        :ok -> {:cont, :ok}
        {:hold, _reason} = hold -> {:halt, hold}
      end
    end)
  end

  @impl FrontSeat.Scheduler
  def dispatch(%Task{} = task) do
    RunSupervisor.start_runner(task.id)
  end
end
