defmodule CodeLead.Tasks do
  @moduledoc """
  The task workflow: Planning → Running → Review → Done, with
  `run_state` tracking execution inside Running.

  The column transitions are **not** hardcoded here. `apply_transition/3`
  looks the requested edge up in the task's `CodeLead.Workflow`
  definition and derives every field change from that edge's policies
  and the target stage's `stage_type`; an edge the definition does not
  contain is `{:error, :invalid_state}`. The functions below name
  specific edges and supply the audit summary — they carry no
  column-specific logic of their own. Every transition records a
  `:transition` task step.

  Human gates own every handoff; the single `trigger: :auto` edge is
  Running → Review on successful completion (`complete_run/1`).

  `run_state` is deliberately outside the workflow graph: dispatch
  (`begin_dispatch/1`, `mark_executing/2`) and failure (`fail_run/2`,
  `retry_run/1`) move a task *within* the Running stage and are not
  edges.

  Transition map (see `docs/task-workflow.md`):

  | Function | From | To |
  |---|---|---|
  | `move_to_running/1` (human) | planning | running, queued |
  | `begin_dispatch/1` (system) | running, queued | running, dispatched |
  | `mark_executing/2` (system) | running, dispatched | running, executing |
  | `complete_run/1` (system) | running, executing | review, idle |
  | `fail_run/2` (system) | running, dispatched/executing | running, failed |
  | `retry_run/1` (human) | running, failed | running, queued |
  | `cancel_run/1` (human) | running, any | planning, idle (worktree kept) |
  | `request_changes/2` (human) | review | running, queued (context kept) |
  | `send_back_to_planning/1` (human) | review | planning (context discarded) |
  | `approve/1` (human) | review | done |

  Side effects that accompany a transition (dispatching the agent,
  fanning out reviewers, finalizing) live in `CodeLead.Runtime`, which
  dispatches them on the same stage types.
  """

  import Ecto.Query

  alias CodeLead.Agents
  alias CodeLead.Agents.Agent
  alias CodeLead.Finalizer
  alias CodeLead.License
  alias CodeLead.Projects
  alias CodeLead.Repo
  alias CodeLead.Tasks.Attention
  alias CodeLead.Tasks.Task
  alias CodeLead.Tasks.TaskReviewer
  alias CodeLead.Tasks.TaskStep
  alias CodeLead.Workflow
  alias CodeLead.Workflow.Stage

  @type transition_error ::
          {:error, :invalid_state}
          | {:error, :no_executor}
          | {:error, :executor_ineligible}
          | {:error, :missing_repository}
          | {:error, :missing_execution_env}
          | {:error, :unlicensed_execution_env}

  @type summary :: %{atom() => non_neg_integer()}

  @empty_summary %{
    planning: 0,
    running: 0,
    review: 0,
    done: 0,
    queued: 0,
    executing: 0,
    failed: 0,
    attention: 0
  }

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

  @doc """
  Subscribes to the organization-wide task topic, which carries every
  project's changes as the same `{:board_changed, project_id, task_id}`
  message. One subscription for a cross-project surface, and projects
  created after the subscriber mounted are covered too.
  """
  @spec subscribe_org() :: :ok | {:error, term()}
  def subscribe_org do
    Phoenix.PubSub.subscribe(CodeLead.PubSub, org_topic())
  end

  @spec board_topic(pos_integer()) :: String.t()
  def board_topic(project_id), do: "project:#{project_id}"

  @spec task_topic(pos_integer()) :: String.t()
  def task_topic(task_id), do: "task:#{task_id}"

  @spec org_topic() :: String.t()
  def org_topic, do: "org:tasks"

  ## Creation & editing

  @doc """
  Creates a task in Planning. Defaults: `target` from work type
  (code → repo, otherwise folder), the project's first repository for
  `:repo` targets, and the project's default reviewers for the work
  type.
  """
  @spec create_task(pos_integer(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(project_id, attrs) do
    changeset =
      %Task{project_id: project_id}
      |> Task.create_changeset(attrs)
      |> validate_licensed_execution_env()

    with {:ok, task} <- Repo.insert(changeset) do
      task
      |> maybe_default_repository()
      |> prefill_reviewers()
      |> then(&broadcast_board_change({:ok, &1}))
    end
  end

  @doc """
  Updates task fields. In Planning everything is editable; afterwards
  only descriptive fields (title, description, spec, priority, ready
  flag, assignee).

  A Planning edit that changes the execution shape is re-normalized the
  same way creation is: a `:repo` target without a repository falls back
  to the project's first one, and a new work type drops an executor that
  is no longer eligible and re-prefills the reviewer set.
  """
  @spec update_task(Task.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update_task(%Task{state: :planning} = task, attrs) do
    changeset =
      task
      |> Task.planning_changeset(attrs)
      |> validate_licensed_execution_env()

    with {:ok, updated} <- Repo.update(changeset) do
      updated
      |> maybe_default_repository()
      |> realign_agents(task.work_type)
      |> then(&broadcast_board_change({:ok, &1}))
    end
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

  ## The workflow machine

  @doc """
  Moves a task along one edge of its workflow.

  The edge is given as `{from, to}` stage keys and must exist in the
  task's definition — anything else is `{:error, :invalid_state}`,
  which is what makes the definition, not this module, the authority on
  which moves are legal. Naming the edge rather than just the target
  matters where two edges share a target: Running → Planning (cancel,
  context kept) and Review → Planning (send back, context discarded).

  Every field change follows from the edge's policies and the target
  stage's type; callers supply only `:actor`, the audit `:summary`,
  and — entering an `:execute` stage — the `:prompt` for the next run.
  """
  @spec apply_transition(Task.t(), {atom(), atom()}, keyword()) ::
          {:ok, Task.t()} | transition_error()
  def apply_transition(%Task{} = task, {from, to}, opts) do
    workflow = Workflow.fetch!(task.workflow_key)

    with :ok <- check_from_stage(task, from),
         {:ok, edge} <- fetch_edge(workflow, from, to),
         target = Workflow.stage(workflow, to),
         :ok <- check_stage_entry(task, target.stage_type) do
      transition(task, transition_changes(edge, target, opts), opts)
    end
  end

  ## Human transitions

  @doc """
  Whether `move_to_running/1` would succeed right now: an eligible
  executor and, for `:repo` targets, a repository. Takes the executor
  agent directly (or `nil`) rather than fetching it by id, so a caller
  that already loaded the project's agents — the board, the task page —
  checks every task without a query each. Exposed so those surfaces can
  hide or disable the Start/Schedule affordances instead of only
  reporting the failure after the fact.
  """
  @spec startable(Task.t(), Agent.t() | nil) ::
          :ok
          | {:error,
             :no_executor
             | :executor_ineligible
             | :missing_repository
             | :missing_execution_env
             | :unlicensed_execution_env}
  def startable(%Task{} = task, executor) do
    with :ok <- check_eligible_executor(task, executor),
         :ok <- check_repository(task) do
      check_execution_env(task)
    end
  end

  @spec startable?(Task.t(), Agent.t() | nil) :: boolean()
  def startable?(%Task{} = task, executor), do: startable(task, executor) == :ok

  @doc """
  Planning → Running. Guarded: the task needs an eligible executor
  and, for `:repo` targets, a repository. Enqueues (`run_state:
  :queued`); the scheduler picks it up from there.
  """
  @spec move_to_running(Task.t()) :: {:ok, Task.t()} | transition_error()
  def move_to_running(%Task{} = task) do
    apply_transition(task, {:planning, :running},
      actor: :human,
      summary: "moved to Running (queued)"
    )
  end

  @doc """
  Aborts a run: Running → Planning. The worktree/branch/session are
  kept for inspection; the agent process is terminated by the runtime.
  """
  @spec cancel_run(Task.t()) :: {:ok, Task.t()} | transition_error()
  def cancel_run(%Task{} = task) do
    apply_transition(task, {:running, :planning},
      actor: :human,
      summary: "run cancelled — back to Planning (worktree kept)"
    )
  end

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
  Drops a queued task's start time so it can be dispatched now. The
  pending wake-up job no-ops on its own once the time no longer
  matches — nothing has to chase it.
  """
  @spec clear_schedule(Task.t()) :: {:ok, Task.t()} | transition_error()
  def clear_schedule(%Task{state: :running, run_state: :queued} = task) do
    transition(task, %{scheduled_at: nil},
      actor: :human,
      summary: "schedule cleared — running now"
    )
  end

  def clear_schedule(%Task{}), do: {:error, :invalid_state}

  @doc """
  Review → Running with the same agent, worktree, branch, and session.
  The feedback becomes the next prompt; commits accumulate.
  """
  @spec request_changes(Task.t(), String.t()) :: {:ok, Task.t()} | transition_error()
  def request_changes(%Task{} = task, feedback) do
    apply_transition(task, {:review, :running},
      actor: :human,
      prompt: feedback,
      summary: "changes requested: #{feedback}"
    )
  end

  @doc """
  Review → Planning, discarding the execution context: worktree
  removed, branch deleted, session cleared. The runtime performs the
  filesystem teardown; here the references are dropped — the edge's
  `:reset` context policy and `:discard` worktree policy say so.
  """
  @spec send_back_to_planning(Task.t()) :: {:ok, Task.t()} | transition_error()
  def send_back_to_planning(%Task{} = task) do
    apply_transition(task, {:review, :planning},
      actor: :human,
      summary: "sent back to Planning — worktree, branch, and session discarded"
    )
  end

  @doc """
  Review → Done. Finalization (commit/push/PR or artifact) is performed
  by the system executor around this transition.

  Entering a `:finalize` stage stamps `completed_at`, the only
  completion timestamp the model has. It is written exactly once:
  nothing reopens a Done task today, so nothing clears it. A future
  reopen transition must set it back to nil or throughput will
  double-count.
  """
  @spec approve(Task.t()) :: {:ok, Task.t()} | transition_error()
  def approve(%Task{} = task) do
    apply_transition(task, {:review, :done}, actor: :human, summary: "approved — Done")
  end

  @doc """
  The finalize mode Approve → Done will actually run: the task's own
  override, else the project default for its target, else the built-in.

  The single place the three sources are joined, so the button label and
  the finalizer cannot disagree about what Approve does.
  """
  @spec finalize_mode(Task.t()) :: Task.finalize_mode()
  def finalize_mode(%Task{target: target, finalize_mode: mode, project_id: project_id}) do
    defaults = Projects.finalize_defaults(project_id)
    Finalizer.resolve_mode(target, mode, Map.fetch!(defaults, target))
  end

  @doc """
  Sets the task's finalize-mode override. A blank value clears it, which
  is not the same as picking the project's current default — it means
  "follow the project", including after the project changes its mind.
  """
  @spec set_finalize_mode(Task.t(), String.t() | nil) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def set_finalize_mode(%Task{} = task, value) do
    task
    |> Task.finalize_changeset(%{finalize_mode: blank_to_nil(value)})
    |> Repo.update()
    |> broadcast_board_change()
  end

  @doc """
  Forgets the worktree the finalizer just pruned.

  `branch_name` deliberately stays: it still names what was pushed or
  merged and the Done card shows it — only the path has stopped being
  true. Written by the finalize stage effects, never by a caller.
  """
  @spec clear_worktree_path(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def clear_worktree_path(%Task{} = task) do
    task
    |> Ecto.Changeset.change(worktree_path: nil)
    |> Repo.update()
    |> broadcast_board_change()
  end

  @doc """
  Records the finalizer's forge link — the PR/MR that Approve → Done
  opened, the merge commit it landed, or the compare link it fell back
  to. Written by the finalize stage effects, never by a caller-supplied
  changeset.
  """
  @spec put_forge_url(Task.t(), String.t(), Task.url_kind()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def put_forge_url(%Task{} = task, url, kind) do
    task
    |> Ecto.Changeset.change(pr_url: url, pr_url_kind: kind)
    |> Repo.update()
    |> broadcast_board_change()
  end

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
    task |> Repo.delete() |> broadcast_board_change()
  end

  def delete_task(%Task{}), do: {:error, :not_deletable}

  ## System transitions (called by the runtime)

  @doc """
  Scheduler admitted the task; provisioning starts. Clears
  `scheduled_at` — the schedule is spent once dispatch begins, so a
  late wake-up job finds nothing left to act on.
  """
  @spec begin_dispatch(Task.t()) :: {:ok, Task.t()} | transition_error()
  def begin_dispatch(%Task{state: :running, run_state: :queued} = task) do
    transition(task, %{run_state: :dispatched, scheduled_at: nil},
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
  human decision — the workflow's one `trigger: :auto` edge.

  Only a live run can complete, so this keeps a `run_state` guard on
  top of the edge lookup: a queued or failed task is in the Running
  stage but has nothing to hand to Review.
  """
  @spec complete_run(Task.t()) :: {:ok, Task.t()} | transition_error()
  def complete_run(%Task{run_state: :executing} = task) do
    apply_transition(task, {:running, :review},
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
  Non-raising lookup, for callers that can outlive the task — a
  scheduled wake-up job may fire after the task was deleted.
  """
  @spec get_task(pos_integer()) :: Task.t() | nil
  def get_task(id), do: Repo.get(Task, id)

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

  ## Aggregates
  #
  # Org-wide readouts for the dashboard. Each is one grouped query for
  # every project — never one query per project — and every one of them
  # excludes archived tasks, except `completions_by_day/1`: archiving
  # hides a card, it does not un-do the work it recorded.

  @doc """
  Org-wide task counts: one entry per Kanban column, plus the three
  `run_state` readouts and the number of tasks waiting on a human.
  """
  @spec board_summary() :: summary()
  def board_summary do
    Repo.all(
      from t in Task,
        where: is_nil(t.archived_at) and t.state != :cancelled,
        group_by: [t.state, t.run_state],
        select:
          {t.state, t.run_state, count(t.id),
           type(fragment("count(*) FILTER (WHERE ? IS NOT NULL)", t.attention), :integer)}
    )
    |> Enum.reduce(@empty_summary, fn {state, run_state, count, attention}, acc ->
      merge_summary(acc, state, run_state, count, attention)
    end)
  end

  @doc """
  The same counts as `board_summary/0`, split per project — the
  dashboard's project breakdown. Projects without tasks are absent.
  """
  @spec project_summaries() :: %{pos_integer() => summary()}
  def project_summaries do
    Repo.all(
      from t in Task,
        where: is_nil(t.archived_at) and t.state != :cancelled,
        group_by: [t.project_id, t.state, t.run_state],
        select:
          {t.project_id, t.state, t.run_state, count(t.id),
           type(fragment("count(*) FILTER (WHERE ? IS NOT NULL)", t.attention), :integer)}
    )
    |> Enum.reduce(%{}, fn {project_id, state, run_state, count, attention}, acc ->
      Map.update(
        acc,
        project_id,
        merge_summary(@empty_summary, state, run_state, count, attention),
        &merge_summary(&1, state, run_state, count, attention)
      )
    end)
  end

  @doc """
  Org-wide count of tasks waiting on a human, keyed by attention type.
  """
  @spec attention_counts() :: %{atom() => non_neg_integer()}
  def attention_counts do
    Repo.all(
      from t in Task,
        where: is_nil(t.archived_at) and not is_nil(t.attention),
        group_by: fragment("?->>'type'", t.attention),
        select: {fragment("?->>'type'", t.attention), count(t.id)}
    )
    |> Map.new(fn {type, count} -> {attention_type(type), count} end)
  end

  @doc """
  Tasks waiting on a human across every project, oldest first.
  """
  @spec org_attention_tasks(pos_integer()) :: [map()]
  def org_attention_tasks(limit) do
    Repo.all(
      from t in Task,
        where: is_nil(t.archived_at) and not is_nil(t.attention),
        order_by: [asc: t.updated_at, asc: t.id],
        limit: ^limit,
        select: %{
          id: t.id,
          project_id: t.project_id,
          title: t.title,
          attention: t.attention,
          at: t.updated_at
        }
    )
  end

  @doc """
  Ids of the tasks sitting in Review — the one state where an execution
  context outlives its run, hosting previews, terminals and reviewer
  execs.
  """
  @spec review_task_ids() :: [pos_integer()]
  def review_task_ids do
    Repo.all(
      from t in Task,
        where: t.state == :review and is_nil(t.archived_at),
        order_by: [asc: t.id],
        select: t.id
    )
  end

  @doc """
  Tasks with a live or pending run across every project, oldest first.
  `run_state` is what the database believes; whether a runner process
  actually exists is the caller's cross-check.
  """
  @spec active_runs() :: [map()]
  def active_runs do
    Repo.all(
      from t in Task,
        left_join: a in Agent,
        on: a.id == t.agent_id,
        where: t.state == :running and t.run_state != :idle and is_nil(t.archived_at),
        order_by: [asc: t.updated_at, asc: t.id],
        select: %{
          id: t.id,
          project_id: t.project_id,
          title: t.title,
          run_state: t.run_state,
          agent_name: a.name,
          harness: a.harness,
          since: t.updated_at
        }
    )
  end

  @doc """
  Tasks approved per day over the last `days` days, keyed by date. Days
  without completions are absent — the caller zero-fills.
  """
  @spec completions_by_day(pos_integer()) :: %{Date.t() => non_neg_integer()}
  def completions_by_day(days) do
    since = window_start(days)

    Repo.all(
      from t in Task,
        where: not is_nil(t.completed_at) and t.completed_at >= ^since,
        group_by: fragment("date(?)", t.completed_at),
        select: {fragment("date(?)", t.completed_at), count(t.id)}
    )
    |> Map.new()
  end

  @doc """
  Mean time from task creation to approval over the last `days` days, in
  milliseconds; nil when nothing completed. This is lead time, not agent
  time — it includes however long the task sat in Planning.
  """
  @spec avg_lead_time_ms(pos_integer()) :: non_neg_integer() | nil
  def avg_lead_time_ms(days) do
    since = window_start(days)

    # `type/2` is load-bearing: without it Postgrex hands back a Decimal
    # and `round/1` raises.
    Repo.one(
      from t in Task,
        where: not is_nil(t.completed_at) and t.completed_at >= ^since,
        select:
          type(
            fragment("avg(extract(epoch from (? - ?)) * 1000)", t.completed_at, t.inserted_at),
            :float
          )
    )
    |> case do
      nil -> nil
      ms -> round(ms)
    end
  end

  @doc """
  The most recently approved tasks across every project, newest first.
  """
  @spec recently_completed(pos_integer()) :: [map()]
  def recently_completed(limit) do
    Repo.all(
      from t in Task,
        where: not is_nil(t.completed_at),
        order_by: [desc: t.completed_at, desc: t.id],
        limit: ^limit,
        select: %{
          id: t.id,
          project_id: t.project_id,
          title: t.title,
          completed_at: t.completed_at
        }
    )
  end

  @doc """
  The newest audit steps across every project, with the task they belong
  to — the dashboard's activity feed. Ordered by id, which is monotonic
  with `inserted_at` and covered by the primary key.
  """
  @spec recent_activity(pos_integer()) :: [map()]
  def recent_activity(limit) do
    Repo.all(
      from s in TaskStep,
        join: t in Task,
        on: t.id == s.task_id,
        order_by: [desc: s.id],
        limit: ^limit,
        select: %{
          id: s.id,
          task_id: s.task_id,
          project_id: t.project_id,
          task_title: t.title,
          executor_type: s.executor_type,
          executor_name: s.executor_name,
          kind: s.kind,
          summary: s.summary,
          at: s.inserted_at
        }
    )
  end

  ## Internals

  defp merge_summary(summary, state, run_state, count, attention) do
    summary
    |> Map.update!(state, &(&1 + count))
    |> Map.update!(:attention, &(&1 + attention))
    |> add_run_state(run_state, count)
  end

  defp add_run_state(summary, run_state, count) when run_state in [:queued, :executing, :failed],
    do: Map.update!(summary, run_state, &(&1 + count))

  defp add_run_state(summary, _run_state, _count), do: summary

  # Ecto serializes the embed with string keys, so the grouped value comes
  # back as a string. Explicit clauses rather than `String.to_existing_atom/1`:
  # nothing from the database becomes an atom, and an unrecognized value
  # surfaces as `:other` instead of crashing the page.
  defp attention_type("run_failed"), do: :run_failed
  defp attention_type("review_ready"), do: :review_ready
  defp attention_type("agent_question"), do: :agent_question
  defp attention_type("permission_request"), do: :permission_request
  defp attention_type(_unknown), do: :other

  defp window_start(days) do
    DateTime.new!(Date.add(Date.utc_today(), -(days - 1)), ~T[00:00:00], "Etc/UTC")
  end

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

  # A select's "inherit" option posts an empty string, which `cast/3`
  # would read as "field omitted" and leave the old override in place.
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Notifies board and organization subscribers after a successful write;
  # passes errors through untouched so it can sit at the end of a pipeline.
  # The two topics carry the same message and have disjoint subscribers —
  # a board watches one project, the dashboard watches the organization.
  defp broadcast_board_change({:ok, %Task{} = task} = result) do
    message = {:board_changed, task.project_id, task.id}

    Phoenix.PubSub.broadcast(CodeLead.PubSub, board_topic(task.project_id), message)
    Phoenix.PubSub.broadcast(CodeLead.PubSub, org_topic(), message)

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

  defp check_from_stage(%Task{state: state}, state), do: :ok
  defp check_from_stage(%Task{}, _from), do: {:error, :invalid_state}

  defp fetch_edge(workflow, from, to) do
    case Workflow.fetch_transition(workflow, from, to) do
      {:ok, edge} -> {:ok, edge}
      :error -> {:error, :invalid_state}
    end
  end

  # Entering an `:execute` stage is the one guarded entry (spec §5.3):
  # there has to be an agent that can actually do the work, and a repo
  # for it to land in. Keyed on the stage type, so any future execute
  # stage inherits it.
  defp check_stage_entry(%Task{} = task, :execute) do
    with :ok <- check_executor(task),
         :ok <- check_repository(task) do
      check_execution_env(task)
    end
  end

  defp check_stage_entry(%Task{}, _stage_type), do: :ok

  # Every field change follows from the edge's policies and the target
  # stage's type — there is no per-column change map anywhere.
  defp transition_changes(edge, %Stage{key: key, stage_type: stage_type}, opts) do
    %{state: key, run_state: run_state_for(stage_type)}
    |> put_attention_policy(edge.trigger)
    |> put_context_policy(edge.context_policy)
    |> put_worktree_policy(edge.worktree_policy)
    |> put_stage_entry(stage_type, opts)
  end

  # A stage that runs work enqueues; every other stage is at rest.
  defp run_state_for(:execute), do: :queued
  defp run_state_for(_stage_type), do: :idle

  # A human acting on the card has resolved whatever flagged it. An
  # automatic completion signal has not — it leaves attention to the
  # entering stage's own effects (the review fan-out raises
  # `:review_ready` when the cycle finishes).
  defp put_attention_policy(changes, :human), do: Map.put(changes, :attention, nil)
  defp put_attention_policy(changes, :auto), do: changes

  defp put_context_policy(changes, :reset) do
    Map.merge(changes, %{acp_session_id: nil, next_prompt: nil})
  end

  defp put_context_policy(changes, :carry), do: changes

  # The filesystem teardown is the runtime's; here the references drop.
  defp put_worktree_policy(changes, :discard) do
    Map.merge(changes, %{worktree_path: nil, branch_name: nil})
  end

  defp put_worktree_policy(changes, :keep), do: changes

  # Entering an execute stage sets the prompt for the run about to
  # start — the feedback on a rework edge, nothing on a fresh start, so
  # a stale prompt is never replayed. `scheduled_at` rides the same
  # rail: absent from the opts means "now", which also clears a value
  # left over from an earlier pass through this stage.
  defp put_stage_entry(changes, :execute, opts) do
    Map.merge(changes, %{
      next_prompt: Keyword.get(opts, :prompt),
      scheduled_at: opts |> Keyword.get(:scheduled_at) |> to_second_precision()
    })
  end

  defp put_stage_entry(changes, :finalize, _opts) do
    Map.put(changes, :completed_at, DateTime.utc_now(:second))
  end

  # Back to a planning stage: whatever start time was authorised no
  # longer applies to a spec that is being rewritten.
  defp put_stage_entry(changes, :plan, _opts), do: Map.put(changes, :scheduled_at, nil)

  defp put_stage_entry(changes, _stage_type, _opts), do: changes

  # `:utc_datetime` refuses microseconds; callers should not have to
  # know that to hand us a timestamp.
  defp to_second_precision(nil), do: nil
  defp to_second_precision(%DateTime{} = at), do: DateTime.truncate(at, :second)

  defp check_executor(%Task{agent_id: nil}), do: {:error, :no_executor}

  defp check_executor(%Task{agent_id: agent_id} = task) do
    check_eligible_executor(task, Agents.get_agent!(agent_id))
  end

  defp check_eligible_executor(%Task{}, nil), do: {:error, :no_executor}

  defp check_eligible_executor(%Task{work_type: work_type, project_id: project_id}, executor) do
    if Agents.eligible?(executor, work_type, project_id, :execute) do
      :ok
    else
      {:error, :executor_ineligible}
    end
  end

  defp check_repository(%Task{target: :repo, repository_id: nil}),
    do: {:error, :missing_repository}

  defp check_repository(%Task{}), do: :ok

  # The persistence half of the container-execution gate. Guards the
  # console path (`Tasks.update_task(task, %{execution_env: :container})`)
  # as much as the form, so an unlicensed instance cannot store the
  # choice at all.
  #
  # Keyed on `get_change/2`, not `get_field/2`: a task already stored as
  # `:container` — minted before the gate, or on an instance whose key has
  # lapsed — must stay editable. Renaming it is not the licensed act;
  # running it is, and `check_execution_env/1` blocks that.
  defp validate_licensed_execution_env(changeset) do
    if Ecto.Changeset.get_change(changeset, :execution_env) == :container and
         not License.feature_enabled?(:container_execution_env) do
      Ecto.Changeset.add_error(changeset, :execution_env, "requires a commercial license")
    else
      changeset
    end
  end

  # Container execution is licensed (ADR-0004, docs/licensing.md), so the
  # entitlement is checked before the repository is even loaded — a
  # community instance gets the same answer whatever its repos declare.
  #
  # Beyond that it queries only for container tasks, so the board's
  # per-card `startable?/2` stays query-free for the common case. There is
  # no fallback environment by design — an undeclared environment blocks
  # the start instead of running somewhere nobody chose.
  defp check_execution_env(
         %Task{target: :repo, execution_env: :container, repository_id: repository_id} = _task
       )
       when not is_nil(repository_id) do
    if License.feature_enabled?(:container_execution_env) do
      check_declared_env(repository_id)
    else
      {:error, :unlicensed_execution_env}
    end
  end

  defp check_execution_env(%Task{}), do: :ok

  defp check_declared_env(repository_id) do
    case Projects.get_repository!(repository_id) do
      %{env_kind: :devcontainer} -> :ok
      _undeclared -> {:error, :missing_execution_env}
    end
  end

  defp maybe_default_repository(%Task{target: :repo, repository_id: nil} = task) do
    case CodeLead.Projects.default_repository(task.project_id) do
      nil -> task
      repository -> task |> Ecto.Changeset.change(repository_id: repository.id) |> Repo.update!()
    end
  end

  defp maybe_default_repository(task), do: task

  # A work type change invalidates both agent selections — they are
  # filtered by work type — so the task is realigned rather than left
  # holding picks that only fail later, at the execute-stage guard.
  defp realign_agents(%Task{work_type: work_type} = task, work_type), do: task

  defp realign_agents(task, _previous_work_type) do
    task |> clear_ineligible_executor() |> prefill_reviewers()
  end

  defp clear_ineligible_executor(%Task{agent_id: nil} = task), do: task

  defp clear_ineligible_executor(task) do
    case check_executor(task) do
      :ok -> task
      {:error, _reason} -> task |> Ecto.Changeset.change(agent_id: nil) |> Repo.update!()
    end
  end

  defp prefill_reviewers(task) do
    default_ids =
      Agents.default_reviewers(task.project_id, task.work_type) |> Enum.map(& &1.id)

    replace_reviewers(task.id, default_ids)
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
