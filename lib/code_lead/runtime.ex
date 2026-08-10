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
  Review → Running with the same agent, worktree, branch, and session:
  the feedback becomes the next prompt and commits accumulate.
  """
  @spec request_changes(Task.t(), String.t()) :: {:ok, Task.t()} | Tasks.transition_error()
  def request_changes(%Task{} = task, feedback) do
    with {:ok, task} <- Tasks.request_changes(task, feedback) do
      try_dispatch(task)
      {:ok, Tasks.get_task!(task.id)}
    end
  end

  @doc """
  Review → Planning with a clean reset: the worktree is removed, the
  feature branch deleted, the session dropped — the spec is being
  rewritten, so prior context is discarded rather than carried forward.
  """
  @spec send_back_to_planning(Task.t()) :: {:ok, Task.t()} | Tasks.transition_error()
  def send_back_to_planning(%Task{} = task) do
    with {:ok, updated} <- Tasks.send_back_to_planning(task) do
      teardown_context(task)
      {:ok, updated}
    end
  end

  @doc """
  Review → Done: runs the system finalizer (commit remainder, push the
  feature branch, PR/compare link — or mark the folder artifact
  complete), then transitions. A finalizer failure keeps the task in
  Review. Returns the outcome map alongside the task.
  """
  @spec approve(Task.t()) ::
          {:ok, Task.t(), CodeLead.Finalizer.outcome()}
          | {:error, term()}
          | Tasks.transition_error()
  def approve(%Task{state: :review} = task) do
    with {:ok, outcome} <- CodeLead.Finalizer.finalize(task),
         {:ok, task} <- Tasks.approve(task) do
      Tasks.record_step(task.id, :commit, :system, "finalizer", outcome.note)
      {:ok, task, outcome}
    end
  end

  def approve(%Task{}), do: {:error, :invalid_state}

  @doc """
  Attempts to dispatch every queued task (in priority order) that the
  scheduler admits. Called after each run completes and after
  human requeue actions.
  """
  @spec kick_queue() :: :ok
  def kick_queue do
    Enum.each(Tasks.queued_tasks(), &try_dispatch/1)
  end

  defp teardown_context(%Task{worktree_path: nil, target: :repo}), do: :ok

  defp teardown_context(%Task{target: :repo} = task) do
    repository = CodeLead.Projects.get_repository!(task.repository_id)

    context = %CodeLead.Executor.Context{
      type: :worktree,
      path: task.worktree_path,
      task_id: task.id,
      base_clone_path: repository.base_clone_path,
      branch_name: task.branch_name
    }

    CodeLead.Executor.impl().teardown(context, keep: false)
  end

  defp teardown_context(%Task{target: :folder} = task) do
    context = %CodeLead.Executor.Context{
      type: :folder,
      path: CodeLead.Workspace.task_folder(task.id),
      task_id: task.id
    }

    CodeLead.Executor.impl().teardown(context, keep: false)
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
