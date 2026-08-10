defmodule CodeLead.Git.DiffHunk do
  @moduledoc """
  One `@@`-delimited hunk of a parsed unified diff. Lines are maps of
  `%{type: :add | :del | :ctx, old_no: integer | nil, new_no: integer |
  nil, text: String.t()}`.
  """

  @type line :: %{
          type: :add | :del | :ctx,
          old_no: non_neg_integer() | nil,
          new_no: non_neg_integer() | nil,
          text: String.t()
        }

  @type t :: %__MODULE__{
          header: String.t(),
          old_start: non_neg_integer(),
          new_start: non_neg_integer(),
          lines: [line()]
        }

  defstruct header: "", old_start: 0, new_start: 0, lines: []
end
