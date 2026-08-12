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
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeLead.Agents.Agent
  alias CodeLead.Tasks.Attention
  alias CodeLead.Tasks.TaskReviewer

  @type t :: %__MODULE__{}

  @work_types [:code, :design, :content, :file]
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
    field :ready_flag, :boolean, default: false
    field :repository_id, :id
    field :worktree_path, :string
    field :branch_name, :string
    field :acp_session_id, :string
    field :next_prompt, :string
    field :scheduled_at, :utc_datetime
    field :assignee_id, :id
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
      :ready_flag,
      :agent_id,
      :repository_id,
      :assignee_id
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
      :ready_flag,
      :agent_id,
      :repository_id,
      :assignee_id
    ])
    |> validate_required([:title, :work_type, :target])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:repository_id)
    |> foreign_key_constraint(:assignee_id)
  end

  @doc """
  Changeset for edits after Planning: descriptive fields only — the
  execution shape (work type, target, repo, executor) is locked.
  """
  @spec details_changeset(t(), map()) :: Ecto.Changeset.t()
  def details_changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :description, :spec, :priority, :ready_flag, :assignee_id])
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
