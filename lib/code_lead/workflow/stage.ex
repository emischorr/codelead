defmodule CodeLead.Workflow.Stage do
  @moduledoc """
  One stage (Kanban column) of a workflow.

  `key` is the persisted `tasks.state` value; `stage_type` is the
  abstract role the machine dispatches on, independent of the stage's
  name, key, or position. `:custom` is the inert default — a holding
  column with no on-enter side effects.
  """

  @type stage_type :: :plan | :execute | :review | :finalize | :custom

  @type t :: %__MODULE__{
          key: atom(),
          name: String.t(),
          position: pos_integer(),
          stage_type: stage_type()
        }

  @enforce_keys [:key, :name, :position]
  defstruct [:key, :name, :position, stage_type: :custom]
end
