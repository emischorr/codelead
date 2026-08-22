defmodule CodeLead.Runtime.StageEffects do
  @moduledoc """
  What entering a stage *does*, dispatched on
  `CodeLead.Workflow.Stage` type rather than on column identity. The
  only place in the runtime that maps a stage to behaviour.

  Two hooks, because one of them has to be able to veto:

  - `prepare/2` runs **before** the state is written and may return
    `{:error, reason}` to abort the transition. `:finalize` uses it —
    a push that fails must leave the task in Review rather than land it
    in Done with nothing pushed.
  - `on_enter/3` runs **after** the write, receiving whatever
    `prepare/2` produced. This is where work starts: dispatching the
    agent, fanning out reviewers.

  `:plan` and `:custom` do nothing. `:custom` is the default stage type,
  so a future column added without an implementation here is inert
  rather than dangerous.
  """

  require Logger

  alias CodeLead.Executor
  alias CodeLead.Executor.Context
  alias CodeLead.Preview
  alias CodeLead.Projects
  alias CodeLead.Reviews
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Runtime.ScheduledDispatchWorker
  alias CodeLead.Scheduler
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Terminal
  alias CodeLead.Workflow.Stage

  @doc """
  Pre-commit hook. `{:error, reason}` aborts the transition before
  anything is written.
  """
  @spec prepare(Stage.stage_type(), Task.t()) :: {:ok, term()} | {:error, term()}
  def prepare(:finalize, %Task{} = task) do
    CodeLead.Finalizer.finalize(task, Tasks.finalize_mode(task))
  end

  def prepare(_stage_type, %Task{}), do: {:ok, nil}

  @doc """
  Post-commit hook, given the task as written and the value `prepare/2`
  produced. Its result is not part of the transition's outcome — the
  task has already moved.
  """
  @spec on_enter(Stage.stage_type(), Task.t(), term()) :: term()
  def on_enter(:execute, %Task{} = task, _prepared) do
    # A run entering means the reviewed build is history — the preview
    # server (if any) stops here, covering request-changes, whose edge
    # keeps the context alive. The terminal deliberately does not: the
    # preview *is* the reviewed artifact and would serve a stale build,
    # while a terminal is a tool the human is holding, and this edge
    # destroys nothing it depends on.
    Preview.stop(task.id)
    try_dispatch(task)
  end

  def on_enter(:review, %Task{} = task, _prepared) do
    {:ok, _cycle} = Reviews.start_cycle(task)
    :ok
  end

  def on_enter(:finalize, %Task{} = task, %{note: note, cleanup: cleanup} = outcome) do
    Tasks.record_step(task.id, :commit, :system, "finalizer", note)
    put_forge_url(task, outcome)
    prune_context(task, cleanup)
    :ok
  end

  def on_enter(_stage_type, %Task{}, _prepared), do: :ok

  @doc """
  Tears the task's execution context down and forgets it: the worktree
  and its feature branch, or the task folder.

  Two callers, deliberately: the `:discard` worktree policy on an edge,
  and a finalize outcome asking to prune. Same teardown either way — the
  difference is only *when* it is known to be safe.

  An error means files survived the teardown. The transition that asked
  for it has already committed, so it is audited here — log plus task
  step — and reported for the caller to surface, never to roll back.
  """
  @spec discard_context(Task.t()) :: :ok | {:error, term()}
  def discard_context(%Task{target: :repo, repository_id: nil}), do: :ok

  def discard_context(%Task{worktree_path: nil, target: :repo} = task) do
    stop_sessions(task.id)
    # No worktree was ever provisioned, but ephemeral resources (a
    # container) may still exist under the task's identity.
    context = rebuilt_context(%{task | worktree_path: CodeLead.Workspace.worktree_path(task.id)})
    _ = context.executor.teardown(context, keep: true)
    :ok
  end

  def discard_context(%Task{} = task) do
    stop_sessions(task.id)
    context = rebuilt_context(task)

    case context.executor.teardown(context, keep: false) do
      :ok -> :ok
      {:error, reason} -> audit_leftover(task, reason)
    end
  end

  @doc """
  Releases the task's ephemeral execution resources — its container —
  while keeping everything durable: worktree, branch, agent home. A
  no-op under `LocalSubprocess`, whose contexts hold nothing ephemeral.
  Two callers: cancel, and the finalize outcomes that keep the context.
  """
  @spec release_context(Task.t()) :: :ok
  def release_context(%Task{target: :repo, repository_id: nil}), do: :ok

  def release_context(%Task{} = task) do
    stop_sessions(task.id)

    context =
      rebuilt_context(%{
        task
        | worktree_path: task.worktree_path || CodeLead.Workspace.worktree_path(task.id)
      })

    # keep: true removes nothing durable, so there is nothing to report.
    _ = context.executor.teardown(context, keep: true)
    :ok
  end

  # The reconstruction the Executor moduledoc warns about: no env, no
  # exec_ref — executor-private state must resolve from the task id.
  # Both sessions hold processes rooted in the context about to be
  # removed — a preview server and a shell's children keep writing into
  # the worktree while it is deleted, which is what turns a teardown
  # into a reported leftover.
  defp stop_sessions(task_id) do
    Preview.stop(task_id)
    Terminal.stop(task_id)
  end

  defp rebuilt_context(%Task{target: :repo} = task) do
    repository = Projects.get_repository!(task.repository_id)

    %Context{
      type: :worktree,
      path: task.worktree_path,
      task_id: task.id,
      base_clone_path: Projects.base_clone_path(repository),
      branch_name: task.branch_name,
      executor: Executor.for_task(task)
    }
  end

  defp rebuilt_context(%Task{target: :folder} = task) do
    %Context{
      type: :folder,
      path: CodeLead.Workspace.task_folder(task.id),
      task_id: task.id,
      executor: Executor.for_task(task)
    }
  end

  defp audit_leftover(%Task{} = task, {tag, path} = reason)
       when tag in [:leftover, :leftover_root_files] do
    Logger.warning("task #{task.id}: worktree could not be removed — leftover at #{path}")

    Tasks.record_step(
      task.id,
      :transition,
      :system,
      "runtime",
      "worktree could not be removed — leftover at #{path}; remove it manually"
    )

    {:error, reason}
  end

  defp audit_leftover(%Task{} = task, reason) do
    Logger.warning("task #{task.id}: context teardown failed — #{inspect(reason)}")
    {:error, reason}
  end

  @doc """
  Asks the scheduler to admit the task and dispatches it if so. A hold
  (over budget, at capacity) is not an error: the task stays queued
  with its badge and the next `CodeLead.Runtime.kick_queue/0` retries.

  A hold on a start time is the one that cannot wait for a passing
  kick, so it books its own wake-up. This is the single `admit?/1`
  call site, so every route into the queued state — a fresh start, a
  rework, a retry, a queue kick — is covered by that one line.
  """
  @spec try_dispatch(Task.t()) :: {:ok, pid()} | {:error, term()} | :hold | nil
  def try_dispatch(%Task{} = task) do
    if RunSupervisor.whereis(task.id) == nil do
      case Scheduler.impl().admit?(task) do
        :ok ->
          Scheduler.impl().dispatch(task)

        {:hold, {:scheduled, at}} ->
          {:ok, _job} = ScheduledDispatchWorker.ensure_enqueued(task.id, at)
          :hold

        {:hold, _reason} ->
          :hold
      end
    end
  end

  # Only after the finalize succeeded, and only in the modes that said
  # so: a `:pull_request` or merged branch lives on the remote, so the
  # worktree is redundant, while a folder artifact *is* the deliverable.
  # Keeping the context still releases the container — Done never leaves
  # one running.
  defp prune_context(%Task{} = task, :keep_context), do: release_context(task)

  defp prune_context(%Task{} = task, :prune_context) do
    # A leftover is logged and recorded inside; the path is dead to the
    # task either way — the work already landed on the remote.
    _ = discard_context(task)
    {:ok, _task} = Tasks.clear_worktree_path(task)
    :ok
  end

  # A folder artifact, and a remote with no forge convention, produce no
  # link — there is nothing to record for those.
  defp put_forge_url(%Task{} = task, %{url: url, url_kind: kind}) do
    Tasks.put_forge_url(task, url, kind)
  end

  defp put_forge_url(%Task{}, _outcome), do: :ok
end
