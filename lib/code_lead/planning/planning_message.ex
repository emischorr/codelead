defmodule CodeLead.Planning.PlanningMessage do
  @moduledoc """
  One turn of a task's planning conversation.

  `kind` records which planning capability produced the turn: `:chat`
  for the `llm_api` assistant's text-only refinement, `:survey` for an
  `:acp` plan agent's read-only repository survey. Only `:chat` turns
  are replayed as history into later completions — a survey report is a
  standalone artifact, not conversational context.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "planning_messages" do
    field :task_id, :id
    field :agent_id, :id
    field :role, Ecto.Enum, values: [:user, :assistant]
    field :kind, Ecto.Enum, values: [:chat, :survey], default: :chat
    field :content, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
