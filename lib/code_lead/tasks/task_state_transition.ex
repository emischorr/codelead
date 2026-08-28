defmodule CodeLead.Tasks.TaskStateTransition do
  @moduledoc """
  History entry for one Kanban-column move of a task. Written once per
  edge taken (`Planning → Running`, `Review → Done`, ...) — never for a
  `run_state`-only change within a stage. The record of "first entry
  into Running" a re-enterable stage otherwise has nowhere to keep.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @states [:planning, :running, :review, :done, :cancelled]

  schema "task_state_transitions" do
    field :task_id, :id
    field :from_state, Ecto.Enum, values: @states
    field :to_state, Ecto.Enum, values: @states

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
