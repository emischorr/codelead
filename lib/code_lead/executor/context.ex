defmodule CodeLead.Executor.Context do
  @moduledoc """
  A provisioned execution context: where the agent works and which env
  it gets. `type` mirrors the task target (`:worktree` for repo,
  `:folder` otherwise).
  """

  @enforce_keys [:type, :path, :task_id]
  defstruct [
    :type,
    :path,
    :task_id,
    :base_clone_path,
    :branch_name,
    :base_branch,
    env: [],
    read_only: false
  ]

  @type t :: %__MODULE__{
          type: :worktree | :folder,
          path: String.t(),
          task_id: pos_integer(),
          base_clone_path: String.t() | nil,
          branch_name: String.t() | nil,
          base_branch: String.t() | nil,
          env: [{String.t(), String.t()}],
          read_only: boolean()
        }
end
