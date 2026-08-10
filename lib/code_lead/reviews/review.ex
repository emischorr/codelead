defmodule CodeLead.Reviews.Review do
  @moduledoc """
  One reviewer's advisory output for one review cycle. Verdicts gate
  nothing — the human weighs them.
  """

  use Ecto.Schema

  alias CodeLead.Agents.Agent

  @type t :: %__MODULE__{}

  schema "reviews" do
    field :task_id, :id
    field :task_step_id, :id
    field :cycle, :integer
    field :verdict, Ecto.Enum, values: [:pass, :concerns, :block]
    field :findings, :string

    belongs_to :agent, Agent

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
