defmodule CodeLead.Tasks.TaskStep do
  @moduledoc """
  Audit-trail entry for a task. Executor identity is denormalized
  (type/name/ref) so deleting an agent leaves history intact. Human steps
  additionally carry `user_id` (nilified on user deletion) with the acting
  user's username in `executor_name`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "task_steps" do
    field :task_id, :id
    field :executor_type, Ecto.Enum, values: [:agent, :system, :human]
    field :executor_name, :string
    field :executor_ref, :string
    field :user_id, :id
    field :kind, Ecto.Enum, values: [:run, :review, :plan, :transition, :commit, :comment]
    field :summary, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
