defmodule CodeLead.Tasks.Task do
  @moduledoc """
  A unit of work moving through Planning → Running → Review → Done.

  Two independent axes describe it: `work_type` (filters selectable
  agents, picks the review renderer) and `target` (where work lands —
  `:repo` = worktree + feature branch, `:folder` = task folder).
  `state` is the Kanban column; `run_state` tracks execution inside
  Running. `archived_at` is orthogonal to `state`. `workflow_key` names
  the `CodeLead.Workflow` definition whose stages those columns are and
  whose edges the transitions must follow.

  `archived_at` and `completed_at` are set by the context alone — they
  appear in no changeset, because a caller-supplied value would corrupt
  the throughput readouts derived from them. `scheduled_at` is set the
  same way, from the transition opts: it is authorisation the human
  gave when moving the card, not an editable attribute of the task.

  `pr_url`/`pr_url_kind` follow the same rule: they are the finalizer's
  own output, written on the Review → Done transition. The kind is what
  lets the UI label the link without re-deriving it from the URL —
  a PR/MR was opened, a merge commit landed, or the forge could only be
  given a compare link.

  `finalize_mode` is the exception among the enums: `nil` is meaningful
  and means *inherit the project default*, so it stays distinguishable
  from any concrete mode when that default later changes. Which modes
  are legal depends on `target`, so it has its own changeset rather than
  riding along in the Planning ones — and because `target` can still
  move in Planning, a mode left over from the other target is possible.
  `CodeLead.Finalizer.resolve_mode/3` ignores such a value rather than
  failing on it.

  `execution_env` selects where the run executes — a `:local`
  subprocess today, a `:container` later. It is a schema seam, unused
  in MVP logic: always `:local` (ADR-0003).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeLead.Agents.Agent
  alias CodeLead.Tasks.Attention
  alias CodeLead.Tasks.TaskReviewer

  @type t :: %__MODULE__{}
  @type url_kind :: :pull_request | :merge_request | :compare | :commit
  @type target :: :repo | :folder
  @type finalize_mode :: :pull_request | :merge | :squash | :artifact | :commit_to_path

  @work_types [:code, :design, :content, :file]
  @url_kinds [:pull_request, :merge_request, :compare, :commit]
  @finalize_modes [:pull_request, :merge, :squash, :artifact, :commit_to_path]
  @execution_envs [:local, :container]
  @states [:planning, :running, :review, :done, :cancelled]
  @run_states [:idle, :queued, :dispatched, :executing, :failed]
  @priorities [:low, :normal, :high, :urgent]

  schema "tasks" do
    field :project_id, :id
    field :title, :string
    field :description, :string
    field :spec, :string
    field :work_type, Ecto.Enum, values: @work_types
    field :target, Ecto.Enum, values: [:repo, :folder]
    field :priority, Ecto.Enum, values: @priorities, default: :normal
    field :workflow_key, :string, default: "builtin.default"
    field :state, Ecto.Enum, values: @states, default: :planning
    field :run_state, Ecto.Enum, values: @run_states, default: :idle
    field :repository_id, :id
    field :worktree_path, :string
    field :branch_name, :string
    field :pr_url, :string
    field :pr_url_kind, Ecto.Enum, values: @url_kinds
    field :finalize_mode, Ecto.Enum, values: @finalize_modes
    field :execution_env, Ecto.Enum, values: @execution_envs, default: :local
    field :acp_session_id, :string
    field :next_prompt, :string
    field :scheduled_at, :utc_datetime
    field :assignee_id, :id
    field :created_by_id, :id
    field :archived_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :parent_id, :id

    belongs_to :agent, Agent
    embeds_one :attention, Attention, on_replace: :delete
    has_many :task_reviewers, TaskReviewer

    timestamps(type: :utc_datetime)
  end

  @doc """
  Is the task waiting on a start time that has not arrived yet?

  The scheduler's admission gate and the queued badge both derive from
  this, so what the UI says and what the scheduler does cannot drift.
  """
  @spec scheduled?(t()) :: boolean()
  def scheduled?(%__MODULE__{scheduled_at: nil}), do: false
  def scheduled?(%__MODULE__{scheduled_at: at}), do: DateTime.after?(at, DateTime.utc_now())

  @doc """
  The finalize modes a target can use. The two sets are disjoint, which
  is what lets `CodeLead.Finalizer.resolve_mode/3` discard a stale
  override by membership alone.
  """
  @spec finalize_modes(target()) :: [finalize_mode()]
  def finalize_modes(:repo), do: [:pull_request, :merge, :squash]
  def finalize_modes(:folder), do: [:artifact, :commit_to_path]

  @doc """
  The mode a target falls back to when neither the task nor the project
  names one. Both are the conservative choice: nothing is merged and
  nothing is pushed anywhere the human did not ask for.
  """
  @spec default_finalize_mode(target()) :: finalize_mode()
  def default_finalize_mode(:repo), do: :pull_request
  def default_finalize_mode(:folder), do: :artifact

  @doc """
  Changeset for the finalize-mode override alone. A blank value clears
  it back to inheriting the project default.
  """
  @spec finalize_changeset(t(), map()) :: Ecto.Changeset.t()
  def finalize_changeset(%__MODULE__{target: target} = task, attrs) do
    task
    |> cast(attrs, [:finalize_mode])
    |> validate_inclusion(:finalize_mode, finalize_modes(target))
  end

  @doc """
  Changeset for creating a task in Planning. `project_id` is set
  programmatically by the context.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :spec,
      :work_type,
      :target,
      :priority,
      :agent_id,
      :repository_id,
      :assignee_id,
      :execution_env
    ])
    |> validate_required([:title, :work_type])
    |> put_default_target()
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:assignee_id)
  end

  @doc """
  Changeset for edits while the task sits in Planning — everything is
  still up for change.
  """
  @spec planning_changeset(t(), map()) :: Ecto.Changeset.t()
  def planning_changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :spec,
      :work_type,
      :target,
      :priority,
      :agent_id,
      :repository_id,
      :assignee_id,
      :execution_env
    ])
    |> validate_required([:title, :work_type, :target])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:assignee_id)
  end

  @doc """
  Changeset for edits after Planning: descriptive fields only — the
  execution shape (work type, target, repo, agent, execution env) is
  locked.
  """
  @spec details_changeset(t(), map()) :: Ecto.Changeset.t()
  def details_changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :spec, :priority, :assignee_id])
    |> validate_required([:title])
    |> foreign_key_constraint(:assignee_id)
  end

  # code defaults to :repo; design/content/file default to :folder.
  defp put_default_target(changeset) do
    case {get_field(changeset, :target), get_field(changeset, :work_type)} do
      {nil, :code} -> put_change(changeset, :target, :repo)
      {nil, work_type} when not is_nil(work_type) -> put_change(changeset, :target, :folder)
      _set -> changeset
    end
  end
end
