defmodule CodeLead.Tasks do
  @moduledoc """
  The task workflow: Planning → Running → Review → Done, with
  `run_state` tracking execution inside Running.

  Every transition function validates the from-state per the
  architecture spec §4 and records a `:transition` task step. Human
  gates own every handoff; the single automatic transition is
  Running → Review on successful completion (`complete_run/1`).

  Transition map (see `docs/task-workflow.md`):

  | Function | From | To |
  |---|---|---|
  | `move_to_running/1` (human) | planning, idle | running, queued |
  | `begin_dispatch/1` (system) | running, queued | running, dispatched |
  | `mark_executing/2` (system) | running, dispatched | running, executing |
  | `complete_run/1` (system) | running, executing | review, idle |
  | `fail_run/2` (system) | running, dispatched/executing | running, failed |
  | `retry_run/1` (human) | running, failed | running, queued |
  | `cancel_run/1` (human) | running, any | planning, idle (worktree kept) |
  | `request_changes/2` (human) | review | running, queued (context kept) |
  | `send_back_to_planning/1` (human) | review | planning (context discarded) |
  | `approve/1` (human) | review | done |
  """

  import Ecto.Query

  alias CodeLead.Agents
  alias CodeLead.Agents.Agent
  alias CodeLead.Repo
  alias CodeLead.Tasks.Attention
  alias CodeLead.Tasks.Task
  alias CodeLead.Tasks.TaskReviewer
  alias CodeLead.Tasks.TaskStep

  @type transition_error ::
          {:error, :invalid_state}
          | {:error, :no_executor}
          | {:error, :executor_ineligible}
          | {:error, :missing_repository}

  ## PubSub

  @doc """
  Subscribes to a project's board topic. Any task change in the project
  arrives as `{:board_changed, project_id, task_id}`.
  """
  @spec subscribe_board(pos_integer()) :: :ok | {:error, term()}
  def subscribe_board(project_id) do
    Phoenix.PubSub.subscribe(CodeLead.PubSub, board_topic(project_id))
  end

  @doc """
  Subscribes to a task's event topic. Runtime and review events arrive
  as `{:task_event, task_id, event}`.
  """
  @spec subscribe_task(pos_integer()) :: :ok | {:error, term()}
  def subscribe_task(task_id) do
    Phoenix.PubSub.subscribe(CodeLead.PubSub, task_topic(task_id))
  end

  @spec board_topic(pos_integer()) :: String.t()
  def board_topic(project_id), do: "project:#{project_id}"

  @spec task_topic(pos_integer()) :: String.t()
  def task_topic(task_id), do: "task:#{task_id}"

  ## Creation & editing

  @doc """
  Creates a task in Planning. Defaults: `target` from work type
  (code → repo, otherwise folder), the project's first repository for
  `:repo` targets, and the project's default reviewers for the work
  type.
  """
  @spec create_task(pos_integer(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(project_id, attrs) do
    changeset = Task.create_changeset(%Task{project_id: project_id}, attrs)

    with {:ok, task} <- Repo.insert(changeset) do
      task
      |> maybe_default_repository()
      |> prefill_reviewers()
      |> then(&{:ok, &1})
    end
  end

  @doc """
  Updates task fields. In Planning everything is editable; afterwards
  only descriptive fields (title, description, spec, priority, ready
  flag, assignee).
  """
  @spec update_task(Task.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update_task(%Task{state: :planning} = task, attrs) do
    task |> Task.planning_changeset(attrs) |> Repo.update() |> broadcast_board_change()
  end

  def update_task(%Task{} = task, attrs) do
    task |> Task.details_changeset(attrs) |> Repo.update() |> broadcast_board_change()
  end

  @doc """
  Sets the executor agent. Planning only; the agent must be an eligible
  executor for the task's work type.
  """
  @spec set_executor(Task.t(), pos_integer()) ::
          {:ok, Task.t()} | transition_error() | {:error, Ecto.Changeset.t()}
  def set_executor(%Task{state: :planning} = task, agent_id) do
    agent = Agents.get_agent!(agent_id)

    if Agents.eligible?(agent, task.work_type, task.project_id, :execute) do
      task |> Ecto.Changeset.change(agent_id: agent.id) |> Repo.update()
    else
      {:error, :executor_ineligible}
    end
  end

  def set_executor(%Task{}, _agent_id), do: {:error, :invalid_state}

  @doc """
  Replaces the task's reviewer set. Every agent must be an eligible
  reviewer for the task's work type.
  """
  @spec set_reviewers(Task.t(), [pos_integer()]) ::
          :ok | {:error, {:ineligible, [pos_integer()]}}
  def set_reviewers(%Task{} = task, agent_ids) do
    eligible_ids =
      MapSet.new(Agents.eligible_reviewers(task.work_type, task.project_id), & &1.id)

    ineligible = Enum.reject(agent_ids, &MapSet.member?(eligible_ids, &1))

    if ineligible == [] do
      replace_reviewers(task.id, agent_ids)
      :ok
    else
      {:error, {:ineligible, ineligible}}
    end
  end

  @doc """
  The task's selected reviewer agents.
  """
  @spec reviewers(pos_integer()) :: [Agent.t()]
  def reviewers(task_id) do
    Repo.all(
      from a in Agent,
        join: tr in TaskReviewer,
        on: tr.agent_id == a.id,
        where: tr.task_id == ^task_id,
        order_by: a.name
    )
  end

  ## Human transitions

  @doc """
  Planning → Running. Guarded: the task needs an eligible executor
  and, for `:repo` targets, a repository. Enqueues (`run_state:
  :queued`); the scheduler picks it up from there.
  """
  @spec move_to_running(Task.t()) :: {:ok, Task.t()} | transition_error()
  def move_to_running(%Task{state: :planning, run_state: :idle} = task) do
    with :ok <- check_executor(task),
         :ok <- check_repository(task) do
      transition(task, %{state: :running, run_state: :queued, next_prompt: nil},
        actor: :human,
        summary: "moved to Running (queued)"
      )
    end
  end

  def move_to_running(%Task{}), do: {:error, :invalid_state}

  @doc """
  Aborts a run: Running → Planning. The worktree/branch/session are
  kept for inspection; the agent process is terminated by the runtime.
  """
  @spec cancel_run(Task.t()) :: {:ok, Task.t()} | transition_error()
  def cancel_run(%Task{state: :running} = task) do
    transition(task, %{state: :planning, run_state: :idle, attention: nil},
      actor: :human,
      summary: "run cancelled — back to Planning (worktree kept)"
    )
  end

  def cancel_run(%Task{}), do: {:error, :invalid_state}

  @doc """
  Re-dispatches a failed run.
  """
  @spec retry_run(Task.t()) :: {:ok, Task.t()} | transition_error()
  def retry_run(%Task{state: :running, run_state: :failed} = task) do
    transition(task, %{run_state: :queued, attention: nil},
      actor: :human,
      summary: "retry after failure (queued)"
    )
  end

  def retry_run(%Task{}), do: {:error, :invalid_state}

  @doc """
  Review → Running with the same agent, worktree, branch, and session.
  The feedback becomes the next prompt; commits accumulate.
  """
  @spec request_changes(Task.t(), String.t()) :: {:ok, Task.t()} | transition_error()
  def request_changes(%Task{state: :review} = task, feedback) do
    transition(
      task,
      %{state: :running, run_state: :queued, next_prompt: feedback, attention: nil},
      actor: :human,
      summary: "changes requested: #{feedback}"
    )
  end

  def request_changes(%Task{}, _feedback), do: {:error, :invalid_state}

  @doc """
  Review → Planning, discarding the execution context: worktree
  removed, branch deleted, session cleared. The runtime performs the
  filesystem teardown; here the references are dropped.
  """
  @spec send_back_to_planning(Task.t()) :: {:ok, Task.t()} | transition_error()
  def send_back_to_planning(%Task{state: :review} = task) do
    transition(
      task,
      %{
        state: :planning,
        run_state: :idle,
        worktree_path: nil,
        branch_name: nil,
        acp_session_id: nil,
        next_prompt: nil,
        attention: nil
      },
      actor: :human,
      summary: "sent back to Planning — worktree, branch, and session discarded"
    )
  end

  def send_back_to_planning(%Task{}), do: {:error, :invalid_state}

  @doc """
  Review → Done. Finalization (commit/push/PR or artifact) is performed
  by the system executor around this transition.
  """
  @spec approve(Task.t()) :: {:ok, Task.t()} | transition_error()
  def approve(%Task{state: :review} = task) do
    transition(task, %{state: :done, run_state: :idle, attention: nil},
      actor: :human,
      summary: "approved — Done"
    )
  end

  def approve(%Task{}), do: {:error, :invalid_state}

  @doc """
  Hides a Done task from board/list queries without deleting it.
  """
  @spec archive(Task.t()) :: {:ok, Task.t()} | transition_error()
  def archive(%Task{state: :done} = task) do
    task
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
    |> Repo.update()
    |> broadcast_board_change()
  end

  def archive(%Task{}), do: {:error, :invalid_state}

  @spec unarchive(Task.t()) :: {:ok, Task.t()}
  def unarchive(%Task{} = task) do
    task |> Ecto.Changeset.change(archived_at: nil) |> Repo.update() |> broadcast_board_change()
  end

  @doc """
  Hard-deletes a task with no pushed artifacts (Planning or Cancelled).
  Steps, reviewers, and messages cascade.
  """
  @spec delete_task(Task.t()) :: {:ok, Task.t()} | {:error, :not_deletable}
  def delete_task(%Task{state: state} = task) when state in [:planning, :cancelled] do
    Repo.delete(task)
  end

  def delete_task(%Task{}), do: {:error, :not_deletable}

  ## System transitions (called by the runtime)

  @doc """
  Scheduler admitted the task; provisioning starts.
  """
  @spec begin_dispatch(Task.t()) :: {:ok, Task.t()} | transition_error()
  def begin_dispatch(%Task{state: :running, run_state: :queued} = task) do
    transition(task, %{run_state: :dispatched},
      actor: :system,
      summary: "dispatched — provisioning execution context"
    )
  end

  def begin_dispatch(%Task{}), do: {:error, :invalid_state}

  @doc """
  The agent process is live. Persists the ACP session id when given
  (kept unchanged on session resume).
  """
  @spec mark_executing(Task.t(), String.t() | nil) :: {:ok, Task.t()} | transition_error()
  def mark_executing(task, acp_session_id \\ nil)

  def mark_executing(%Task{state: :running, run_state: :dispatched} = task, acp_session_id) do
    changes =
      if acp_session_id,
        do: %{run_state: :executing, acp_session_id: acp_session_id},
        else: %{run_state: :executing}

    transition(task, changes, actor: :system, summary: "agent executing")
  end

  def mark_executing(%Task{}, _acp_session_id), do: {:error, :invalid_state}

  @doc """
  Successful completion: Running → Review. A completion signal, not a
  human decision — the one automatic column change.
  """
  @spec complete_run(Task.t()) :: {:ok, Task.t()} | transition_error()
  def complete_run(%Task{state: :running, run_state: :executing} = task) do
    transition(task, %{state: :review, run_state: :idle},
      actor: :system,
      summary: "run completed — moved to Review"
    )
  end

  def complete_run(%Task{}), do: {:error, :invalid_state}

  @doc """
  Agent error/crash: the task stays in Running with an error attention
  badge; the human decides retry vs abort. Never silently stuck.
  """
  @spec fail_run(Task.t(), String.t()) :: {:ok, Task.t()} | transition_error()
  def fail_run(%Task{state: :running, run_state: run_state} = task, detail)
      when run_state in [:queued, :dispatched, :executing] do
    transition(
      task,
      %{run_state: :failed, attention: %{type: :run_failed, detail: detail}},
      actor: :system,
      summary: "run failed: #{detail}"
    )
  end

  def fail_run(%Task{}, _detail), do: {:error, :invalid_state}

  @doc """
  Persists the provisioned execution context (worktree + branch) on the
  task. Called by the executor during dispatch.
  """
  @spec set_execution_context(Task.t(), String.t(), String.t()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def set_execution_context(%Task{} = task, worktree_path, branch_name) do
    task
    |> Ecto.Changeset.change(worktree_path: worktree_path, branch_name: branch_name)
    |> Repo.update()
  end

  @doc """
  Persists the ACP session id reported by the driver, for later resume.
  """
  @spec put_acp_session(Task.t(), String.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def put_acp_session(%Task{} = task, session_id) do
    task
    |> Ecto.Changeset.change(acp_session_id: session_id)
    |> Repo.update()
  end

  @doc """
  Queued tasks across all projects, highest priority first — the
  scheduler's work list.
  """
  @spec queued_tasks() :: [Task.t()]
  def queued_tasks do
    Repo.all(
      from t in Task,
        where: t.state == :running and t.run_state == :queued and is_nil(t.archived_at),
        order_by: [desc: t.priority, asc: t.updated_at]
    )
  end

  ## Attention

  @spec set_attention(Task.t(), atom(), String.t() | nil, keyword()) :: {:ok, Task.t()}
  def set_attention(%Task{} = task, type, detail, opts \\ []) do
    task
    |> Ecto.Changeset.change()
    |> put_attention(%{type: type, detail: detail, ref: opts[:ref]})
    |> Repo.update()
    |> broadcast_board_change()
  end

  @spec clear_attention(Task.t()) :: {:ok, Task.t()}
  def clear_attention(%Task{} = task) do
    task
    |> Ecto.Changeset.change()
    |> put_attention(nil)
    |> Repo.update()
    |> broadcast_board_change()
  end

  ## Audit trail

  @doc """
  Records an audit step. Executor identity is denormalized so history
  survives agent deletion.
  """
  @spec record_step(pos_integer(), atom(), atom(), String.t(), String.t(), String.t() | nil) ::
          TaskStep.t()
  def record_step(task_id, kind, executor_type, executor_name, summary, executor_ref \\ nil) do
    Repo.insert!(%TaskStep{
      task_id: task_id,
      kind: kind,
      executor_type: executor_type,
      executor_name: executor_name,
      executor_ref: executor_ref,
      summary: summary
    })
  end

  @spec steps(pos_integer()) :: [TaskStep.t()]
  def steps(task_id) do
    Repo.all(from s in TaskStep, where: s.task_id == ^task_id, order_by: [asc: s.id])
  end

  @doc """
  The latest finalizer commit note per task (e.g. the pushed-branch or
  artifact summary shown on Done cards).
  """
  @spec commit_notes([pos_integer()]) :: %{pos_integer() => String.t()}
  def commit_notes([]), do: %{}

  def commit_notes(task_ids) do
    Repo.all(
      from s in TaskStep,
        where: s.task_id in ^task_ids and s.kind == :commit,
        order_by: [asc: s.id],
        select: {s.task_id, s.summary}
    )
    |> Map.new()
  end

  ## Queries

  @spec get_task!(pos_integer()) :: Task.t()
  def get_task!(id), do: Repo.get!(Task, id)

  @doc """
  The Kanban board for a project: non-archived tasks grouped by column.
  """
  @spec board(pos_integer()) :: %{(:planning | :running | :review | :done) => [Task.t()]}
  def board(project_id) do
    tasks =
      Repo.all(
        from t in Task,
          where: t.project_id == ^project_id and is_nil(t.archived_at),
          where: t.state != :cancelled,
          order_by: [desc: t.priority, asc: t.updated_at]
      )

    empty = %{planning: [], running: [], review: [], done: []}

    Enum.reduce(tasks, empty, fn task, acc ->
      Map.update!(acc, task.state, &(&1 ++ [task]))
    end)
  end

  @doc """
  Non-archived tasks needing a human, for the attention counter.
  """
  @spec attention_tasks(pos_integer()) :: [Task.t()]
  def attention_tasks(project_id) do
    Repo.all(
      from t in Task,
        where: t.project_id == ^project_id and is_nil(t.archived_at),
        where: not is_nil(t.attention),
        order_by: [asc: t.updated_at]
    )
  end

  ## Internals

  defp transition(task, changes, opts) do
    actor = Keyword.fetch!(opts, :actor)
    summary = Keyword.fetch!(opts, :summary)

    {attention, changes} = Map.pop(changes, :attention, :unchanged)

    changeset =
      task
      |> Ecto.Changeset.change(changes)
      |> put_transition_attention(attention)

    with {:ok, updated} <- Repo.update(changeset) do
      record_step(updated.id, :transition, actor, Atom.to_string(actor), summary)
      broadcast_board_change({:ok, updated})
    end
  end

  # Notifies board and task subscribers after a successful write; passes
  # errors through untouched so it can sit at the end of a pipeline.
  defp broadcast_board_change({:ok, %Task{} = task} = result) do
    Phoenix.PubSub.broadcast(
      CodeLead.PubSub,
      board_topic(task.project_id),
      {:board_changed, task.project_id, task.id}
    )

    result
  end

  defp broadcast_board_change(other), do: other

  defp put_transition_attention(changeset, :unchanged), do: changeset
  defp put_transition_attention(changeset, attention), do: put_attention(changeset, attention)

  defp put_attention(changeset, nil) do
    Ecto.Changeset.put_embed(changeset, :attention, nil)
  end

  defp put_attention(changeset, %{type: type, detail: detail} = attrs) do
    attention =
      Attention.changeset(%Attention{}, %{
        type: type,
        detail: detail,
        ref: Map.get(attrs, :ref),
        at: DateTime.utc_now(:second)
      })

    Ecto.Changeset.put_embed(changeset, :attention, attention)
  end

  defp check_executor(%Task{agent_id: nil}), do: {:error, :no_executor}

  defp check_executor(%Task{agent_id: agent_id} = task) do
    agent = Agents.get_agent!(agent_id)

    if Agents.eligible?(agent, task.work_type, task.project_id, :execute) do
      :ok
    else
      {:error, :executor_ineligible}
    end
  end

  defp check_repository(%Task{target: :repo, repository_id: nil}),
    do: {:error, :missing_repository}

  defp check_repository(%Task{}), do: :ok

  defp maybe_default_repository(%Task{target: :repo, repository_id: nil} = task) do
    case CodeLead.Projects.default_repository(task.project_id) do
      nil -> task
      repository -> task |> Ecto.Changeset.change(repository_id: repository.id) |> Repo.update!()
    end
  end

  defp maybe_default_repository(task), do: task

  defp prefill_reviewers(task) do
    default_ids =
      Agents.default_reviewers(task.project_id, task.work_type) |> Enum.map(& &1.id)

    if default_ids != [], do: replace_reviewers(task.id, default_ids)
    task
  end

  defp replace_reviewers(task_id, agent_ids) do
    now = DateTime.utc_now(:second)

    entries =
      Enum.map(agent_ids, fn agent_id ->
        %{task_id: task_id, agent_id: agent_id, inserted_at: now, updated_at: now}
      end)

    Repo.transaction(fn ->
      Repo.delete_all(from tr in TaskReviewer, where: tr.task_id == ^task_id)
      Repo.insert_all(TaskReviewer, entries)
    end)
  end
end
