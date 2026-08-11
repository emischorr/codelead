defmodule CodeLead.AgentFeed.AgentEvent do
  @moduledoc """
  One entry of a task's executor transcript — the durable form of the
  driver's normalized event stream, rendered by the Agent tab.

  Distinct from `CodeLead.Tasks.TaskStep`, which is the coarse workflow
  audit trail behind the Task tab's timeline.

  `text` carries the human-readable body (message text, tool title,
  question, failure detail); `data` carries the string-keyed extras
  (`"status"`, `"tool_kind"`, `"locations"`, `"input"`, `"resolved"`,
  `"cost_cents"`, `"tokens"`). `streaming` marks the message row the
  runner is still appending to.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds [:run_started, :message, :tool_call, :question, :permission, :result]

  schema "agent_events" do
    field :task_id, :id
    field :task_step_id, :id
    field :kind, Ecto.Enum, values: @kinds
    field :text, :string
    field :external_id, :string
    field :streaming, :boolean, default: false
    field :data, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts an insert or an in-place update of a transcript row.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:task_id, :task_step_id, :kind, :text, :external_id, :streaming, :data])
    |> validate_required([:task_id, :kind])
  end

  @spec kinds() :: [atom()]
  def kinds, do: @kinds
end
