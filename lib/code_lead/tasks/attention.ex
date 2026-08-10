defmodule CodeLead.Tasks.Attention do
  @moduledoc """
  Embedded marker that a task needs a human: what kind, free-text
  detail, and when it was raised. A field on the task — deliberately no
  per-user notification fan-out.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @types [:run_failed, :review_ready, :agent_question, :permission_request]

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: @types
    field :detail, :string
    field :ref, :string
    field :at, :utc_datetime
  end

  @doc """
  Changeset for raising attention. `ref` carries an opaque reference back
  to the raiser (e.g. the pending permission request id).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attention, attrs) do
    attention
    |> cast(attrs, [:type, :detail, :ref, :at])
    |> validate_required([:type, :at])
  end
end
