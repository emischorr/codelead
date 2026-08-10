defmodule CodeLead.Agents.ProjectDefaultReviewer do
  @moduledoc """
  Pre-fills a new task's reviewer set for a work type. Editable per
  task afterwards.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "project_default_reviewers" do
    field :project_id, :id
    field :work_type, Ecto.Enum, values: [:code, :design, :content, :file]
    field :agent_id, :id

    timestamps(type: :utc_datetime)
  end
end
