defmodule CodeLead.Tasks.TaskStep do
  @moduledoc """
  Audit-trail entry for a task. Executor identity is denormalized
  (type/name/ref) so deleting an agent leaves history intact.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "task_steps" do
    field :task_id, :id
    field :executor_type, Ecto.Enum, values: [:agent, :system, :human]
    field :executor_name, :string
    field :executor_ref, :string
    field :kind, Ecto.Enum, values: [:run, :review, :transition, :commit, :comment]
    field :summary, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
