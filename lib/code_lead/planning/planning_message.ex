defmodule CodeLead.Planning.PlanningMessage do
  @moduledoc """
  One turn of a task's planning-assistant chat.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "planning_messages" do
    field :task_id, :id
    field :role, Ecto.Enum, values: [:user, :assistant]
    field :content, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
