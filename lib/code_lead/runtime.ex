defmodule CodeLead.Runtime do
  @moduledoc """
  Human-facing run control: the workflow transitions that carry runtime
  side effects (dispatching agents, terminating processes, tearing down
  contexts). Pure data transitions stay in `CodeLead.Tasks`; the
  LiveViews and the IEx console call these functions.

  `advance/3` is the machine. It resolves the requested edge in the
  task's `CodeLead.Workflow` definition, runs the target stage's
  effects around the write, and applies the edge's worktree policy —
  all dispatched on the stage's `stage_type`, so nothing here knows a
  column by name. The functions below name edges and supply summaries.
  """

  alias CodeLead.AgentDriver
  alias CodeLead.Accounts.Policy
  alias CodeLead.Accounts.Scope
  alias CodeLead.Runtime.StageEffects
  alias CodeLead.Runtime.TaskRunner
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Workflow

  @doc """
  Moves a task along one edge of its workflow, with side effects.

  Ordering is load-bearing: the edge is resolved first, so an illegal
  move costs nothing; the target stage's `prepare/2` runs next and can
  still veto (a failed push leaves the task in Review); only then is
  the state written, the worktree policy applied, and the stage's
  `on_enter/3` fired. Returns the reloaded task plus whatever
  `prepare/2` produced, plus the worktree policy's outcome — a discard
  that leaves files behind does not undo the committed transition, but
  the caller must be able to surface it.
  """
  @spec advance(Task.t(), {atom(), atom()}, keyword()) ::
          {:ok, Task.t(), term(), :ok | {:error, term()}} | {:error, term()}
  def advance(%Task{} = task, {_from, to} = edge_keys, opts) do
    workflow = Workflow.fetch!(task.workflow_key)
    target = Workflow.stage(workflow, to)

    with :ok <- authorize_actor(task, opts),
         {:ok, edge} <- fetch_edge(workflow, task, edge_keys),
         {:ok, prepared} <- StageEffects.prepare(target.stage_type, task),
         {:ok, updated} <- Tasks.apply_transition(task, edge_keys, opts) do
      cleanup = apply_worktree_policy(task, edge.worktree_policy)
      StageEffects.on_enter(target.stage_type, updated, prepared)
      {:ok, Tasks.get_task!(task.id), prepared, cleanup}
    end
  end

  @doc """
  Planning → Running: enqueues the task and lets the scheduler admit
  and dispatch it. Returns the task (queued or already dispatching).

  `:scheduled_at` defers *dispatch*, not the move — the card enters
  Running now, because moving it is the authorisation, and waits there
  until its time comes. The executor guard therefore fires when the
  human schedules rather than at 2am.
  """
  @spec start_task(Scope.t() | nil, Task.t(), keyword()) ::
          {:ok, Task.t()} | Tasks.transition_error()
  def start_task(scope, %Task{} = task, opts \\ []) do
    summary =
      case Keyword.get(opts, :scheduled_at) do
        nil -> "moved to Running (queued)"
        at -> "moved to Running — scheduled for #{DateTime.to_iso8601(at)}"
      end

    task
    |> advance(
      {:planning, :running},
      Keyword.merge(opts, actor: :human, scope: scope, summary: summary)
    )
    |> to_result()
  end

  @doc """
  Drops a queued task's start time and dispatches it immediately.
  """
  @spec run_now(Scope.t() | nil, Task.t()) :: {:ok, Task.t()} | Tasks.transition_error()
  def run_now(scope, %Task{} = task) do
    with {:ok, task} <- Tasks.clear_schedule(scope, task) do
      StageEffects.try_dispatch(task)
      {:ok, Tasks.get_task!(task.id)}
    end
  end

  @doc """
  Aborts a run: terminates the agent, returns the card to Planning,
  keeps the worktree for inspection.
  """
  @spec cancel_task(Scope.t() | nil, Task.t()) :: {:ok, Task.t()} | Tasks.transition_error()
  def cancel_task(scope, %Task{} = task) do
    _ = TaskRunner.cancel(task.id)

    result =
      task
      |> advance({:running, :planning},
        actor: :human,
        scope: scope,
        summary: "run cancelled — back to Planning (worktree kept)"
      )
      |> to_result()

    # The worktree stays for inspection; the container is cattle and
    # goes. Restarting the task re-ensures it.
    with {:ok, cancelled} <- result, do: StageEffects.release_context(cancelled)
    result
  end

  @doc """
  Re-queues a failed run and kicks the scheduler. A retry stays inside
  the Running stage — it moves `run_state`, not the card — so it is not
  a workflow edge.
  """
  @spec retry_task(Scope.t() | nil, Task.t()) :: {:ok, Task.t()} | Tasks.transition_error()
  def retry_task(scope, %Task{} = task) do
    with {:ok, task} <- Tasks.retry_run(scope, task) do
      StageEffects.try_dispatch(task)
      {:ok, Tasks.get_task!(task.id)}
    end
  end

  @doc """
  Approves a surfaced permission escalation (or denies it).
  """
  @spec answer_permission(Scope.t() | nil, Task.t(), term(), boolean()) ::
          :ok | {:error, term()}
  def answer_permission(scope, %Task{} = task, request_id, granted?) do
    with :ok <- Policy.authorize(scope, :operate_task, task) do
      TaskRunner.answer_permission(task.id, request_id, granted?)
    end
  end

  @doc """
  Settles a surfaced agent question, releasing the blocked run.

  `{:accept, answers}` hands the answers over, `:decline` skips the
  question (the agent proceeds without one), and `:cancel` aborts the
  request outright.
  """
  @spec answer_question(Scope.t() | nil, Task.t(), term(), AgentDriver.question_answer()) ::
          :ok | {:error, term()}
  def answer_question(scope, %Task{} = task, request_id, answer) do
    with :ok <- Policy.authorize(scope, :operate_task, task) do
      TaskRunner.answer_question(task.id, request_id, answer)
    end
  end

  @doc """
  Review → Running with the same agent, worktree, branch, and session:
  the feedback becomes the next prompt and commits accumulate.
  """
  @spec request_changes(Scope.t() | nil, Task.t(), String.t()) ::
          {:ok, Task.t()} | Tasks.transition_error()
  def request_changes(scope, %Task{} = task, feedback) do
    task
    |> advance({:review, :running},
      actor: :human,
      scope: scope,
      prompt: feedback,
      summary: "changes requested: #{feedback}"
    )
    |> to_result()
  end

  @doc """
  Review → Planning with a clean reset: the worktree is removed, the
  feature branch deleted, the session dropped — the spec is being
  rewritten, so prior context is discarded rather than carried forward.

  A discard that leaves files behind (root-owned leftovers of a
  container run) still transitions — the human's decision stands — but
  comes back as `{:ok, task, {:cleanup_failed, reason}}` so the UI can
  say so instead of flashing a clean success.
  """
  @spec send_back_to_planning(Scope.t() | nil, Task.t()) ::
          {:ok, Task.t()}
          | {:ok, Task.t(), {:cleanup_failed, term()}}
          | Tasks.transition_error()
  def send_back_to_planning(scope, %Task{} = task) do
    task
    |> advance({:review, :planning},
      actor: :human,
      scope: scope,
      summary: "sent back to Planning — worktree, branch, and session discarded"
    )
    |> to_result()
  end

  @doc """
  Running → Review on successful completion — the workflow's one
  automatic edge. Fans out the reviewers on entry. Called by the task
  runner, not by a human.
  """
  @spec complete_run(Task.t()) :: {:ok, Task.t()} | Tasks.transition_error()
  def complete_run(%Task{} = task) do
    task
    |> advance({:running, :review},
      actor: :system,
      summary: "run completed — moved to Review"
    )
    |> to_result()
  end

  @doc """
  Review → Done: runs the system finalizer in the task's resolved
  finalize mode — open a PR, merge or squash-merge the branch, hand the
  folder artifact over, or commit it to a repository path — then
  transitions. A finalizer failure keeps the task in Review. Returns the
  outcome map alongside the task.
  """
  @spec approve(Scope.t() | nil, Task.t()) ::
          {:ok, Task.t(), CodeLead.Finalizer.outcome()}
          | {:error, term()}
          | Tasks.transition_error()
  def approve(scope, %Task{} = task) do
    # The Review → Done edge keeps the worktree (pruning is the finalize
    # outcome's call, applied in on_enter), so the cleanup element is
    # structurally :ok and carries nothing worth surfacing.
    case advance(task, {:review, :done},
           actor: :human,
           scope: scope,
           summary: "approved — Done"
         ) do
      {:ok, task, outcome, _cleanup} -> {:ok, task, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Attempts to dispatch every queued task (in priority order) that the
  scheduler admits. Called after each run completes and after
  human requeue actions.
  """
  @spec kick_queue() :: :ok
  def kick_queue do
    Enum.each(Tasks.queued_tasks(), &StageEffects.try_dispatch/1)
  end

  # Human moves must be authorized before any side effect fires; system
  # moves (the runtime's own Running → Review) carry no scope and pass.
  defp authorize_actor(task, opts) do
    case Keyword.fetch!(opts, :actor) do
      :human -> Policy.authorize(opts[:scope], :operate_task, task)
      :system -> :ok
    end
  end

  # The task must sit at the edge's from-stage; `Tasks.apply_transition/3`
  # checks this again, but the edge has to resolve before `prepare/2`
  # runs so an illegal move never reaches a side effect.
  defp fetch_edge(workflow, %Task{state: state}, {from, to}) when state == from do
    case Workflow.fetch_transition(workflow, from, to) do
      {:ok, edge} -> {:ok, edge}
      :error -> {:error, :invalid_state}
    end
  end

  defp fetch_edge(_workflow, %Task{}, _edge_keys), do: {:error, :invalid_state}

  defp apply_worktree_policy(%Task{} = task, :discard), do: StageEffects.discard_context(task)
  defp apply_worktree_policy(%Task{}, :keep), do: :ok

  # Only `approve/1` surfaces what the stage prepared; the rest keep the
  # two-tuple their callers pattern-match on — extended by a
  # `:cleanup_failed` element only when a discard actually left files
  # behind, so `:keep`-edge callers never see a shape change.
  defp to_result({:ok, task, _prepared, :ok}), do: {:ok, task}

  defp to_result({:ok, task, _prepared, {:error, reason}}),
    do: {:ok, task, {:cleanup_failed, reason}}

  defp to_result({:error, reason}), do: {:error, reason}
end
