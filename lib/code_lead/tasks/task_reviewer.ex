defmodule CodeLead.Tasks.TaskReviewer do
  @moduledoc """
  One selected reviewer agent for a task. The set is pre-filled from
  the project's default reviewers and stays editable per task.
  """

  use Ecto.Schema

  alias CodeLead.Agents.Agent

  @type t :: %__MODULE__{}

  schema "task_reviewers" do
    field :task_id, :id

    belongs_to :agent, Agent

    timestamps(type: :utc_datetime)
  end
end
