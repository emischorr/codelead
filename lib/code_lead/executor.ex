defmodule CodeLead.Executor do
  @moduledoc """
  Behaviour for provisioning and tearing down task execution contexts
  and spawning agent processes inside them.

  MVP implementation: `CodeLead.Executor.LocalSubprocess`. Later:
  `DockerContainer` wrapping the same agent subprocess in a sibling
  container. The agent driver is independent of the executor.
  """

  alias CodeLead.Executor.Context
  alias CodeLead.Tasks.Task

  @doc """
  Creates the execution context for a task by target: `:repo` → base
  clone + git worktree on the feature branch, `:folder` → task folder.
  Idempotent across runs of the same task (multi-run reuses the
  worktree).
  """
  @callback provision(task :: Task.t()) :: {:ok, Context.t()} | {:error, term()}

  @doc """
  Spawns an OS process inside the context with the project env
  injected, returning the connected port.
  """
  @callback spawn(context :: Context.t(), command :: [String.t()], port_opts :: keyword()) ::
              {:ok, port()} | {:error, term()}

  @doc """
  Tears the context down. `keep: true` leaves everything on disk (the
  cancel/inspection path); `keep: false` removes the worktree/folder
  and deletes the feature branch (the send-back-to-planning path).
  """
  @callback teardown(context :: Context.t(), opts :: keyword()) :: :ok

  @doc """
  The configured executor implementation.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:code_lead, :executor, CodeLead.Executor.LocalSubprocess)
  end
end
