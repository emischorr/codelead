defmodule CodeLead.Executor.Context do
  @moduledoc """
  A provisioned execution context: where the agent works and which env
  it gets. `type` mirrors the task target (`:worktree` for repo,
  `:folder` otherwise).

  `exec_ref` is the executor's private identity for the provisioned
  environment — `nil` under `LocalSubprocess`, the container name under
  `DockerContainer`. It is not durable: teardown may receive a context
  rebuilt from DB rows without it, so no implementation may depend on it
  for teardown (ADR-0003).

  `executor` is the module whose `spawn/3`/`teardown/2` operate on this
  context. Stamped at provisioning/construction; the default keeps
  hand-built contexts (planning surveys) on the local executor.
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
    read_only: false,
    exec_ref: nil,
    executor: CodeLead.Executor.LocalSubprocess
  ]

  @type t :: %__MODULE__{
          type: :worktree | :folder,
          path: String.t(),
          task_id: pos_integer(),
          base_clone_path: String.t() | nil,
          branch_name: String.t() | nil,
          base_branch: String.t() | nil,
          env: [{String.t(), String.t()}],
          read_only: boolean(),
          exec_ref: term() | nil,
          executor: module()
        }
end
