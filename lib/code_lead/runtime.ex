defmodule CodeLead.Runtime do
  @moduledoc """
  Human-facing run control: the workflow transitions that carry runtime
  side effects (dispatching agents, terminating processes, tearing down
  contexts). Pure data transitions stay in `CodeLead.Tasks`; the future
  LiveView calls these functions.
  """

  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Runtime.TaskRunner
  alias CodeLead.Scheduler
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task

  @doc """
  Planning → Running: enqueues the task and lets the scheduler admit
  and dispatch it. Returns the task (queued or already dispatching).
  """
  @spec start_task(Task.t()) :: {:ok, Task.t()} | Tasks.transition_error()
  def start_task(%Task{} = task) do
    with {:ok, task} <- Tasks.move_to_running(task) do
      try_dispatch(task)
      {:ok, Tasks.get_task!(task.id)}
    end
  end

  @doc """
  Aborts a run: terminates the agent, returns the card to Planning,
  keeps the worktree for inspection.
  """
  @spec cancel_task(Task.t()) :: {:ok, Task.t()} | Tasks.transition_error()
  def cancel_task(%Task{} = task) do
    _ = TaskRunner.cancel(task.id)
    Tasks.cancel_run(task)
  end

  @doc """
  Re-queues a failed run and kicks the scheduler.
  """
  @spec retry_task(Task.t()) :: {:ok, Task.t()} | Tasks.transition_error()
  def retry_task(%Task{} = task) do
    with {:ok, task} <- Tasks.retry_run(task) do
      try_dispatch(task)
      {:ok, Tasks.get_task!(task.id)}
    end
  end

  @doc """
  Approves a surfaced permission escalation (or denies it).
  """
  @spec answer_permission(Task.t(), term(), boolean()) :: :ok | {:error, term()}
  def answer_permission(%Task{} = task, request_id, granted?) do
    TaskRunner.answer_permission(task.id, request_id, granted?)
  end

  @doc """
  Attempts to dispatch every queued task (in priority order) that the
  scheduler admits. Called after each run completes and after
  human requeue actions.
  """
  @spec kick_queue() :: :ok
  def kick_queue do
    Enum.each(Tasks.queued_tasks(), &try_dispatch/1)
  end

  defp try_dispatch(%Task{} = task) do
    if RunSupervisor.whereis(task.id) == nil do
      case Scheduler.impl().admit?(task) do
        :ok -> Scheduler.impl().dispatch(task)
        {:hold, _reason} -> :hold
      end
    end
  end
end
