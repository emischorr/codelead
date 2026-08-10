defmodule CodeLead.Git.DiffFile do
  @moduledoc """
  One file's worth of a parsed unified diff.
  """

  alias CodeLead.Git.DiffHunk

  @type status :: :added | :deleted | :modified | :renamed

  @type t :: %__MODULE__{
          old_path: String.t() | nil,
          new_path: String.t() | nil,
          status: status(),
          additions: non_neg_integer(),
          deletions: non_neg_integer(),
          binary?: boolean(),
          hunks: [DiffHunk.t()]
        }

  defstruct old_path: nil,
            new_path: nil,
            status: :modified,
            additions: 0,
            deletions: 0,
            binary?: false,
            hunks: []

  @doc "The path to display: the new path, falling back to the old one."
  @spec path(t()) :: String.t()
  def path(%__MODULE__{new_path: nil, old_path: old_path}), do: old_path
  def path(%__MODULE__{new_path: new_path}), do: new_path
end
