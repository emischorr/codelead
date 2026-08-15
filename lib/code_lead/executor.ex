defmodule CodeLead.Executor do
  @moduledoc """
  Behaviour for provisioning and tearing down task execution contexts
  and spawning agent processes inside them.

  The locked contract (ADR-0003): `spawn/3` launches the agent process
  *inside* the provisioned execution context. Under the future
  `DockerContainer` implementation the ACP harness runs in the sibling
  container, attached over `docker exec -i` — the same Port stdio
  bridge as today. Client-side ACP capabilities (permission prompts,
  display) stay host-side in the driver; they are not the executor's
  concern.

  Implementations must not assume a `Context` round-trips intact:
  `CodeLead.Runtime.StageEffects.discard_context/1` rebuilds one from
  DB rows with no `env` and no `exec_ref` before calling `teardown/2`,
  so executor-private state must be recoverable from the task id alone
  (e.g. container labels). Implementations must also default `spawn/3`'s
  `port_opts` — callers use `spawn/2`. An implementation may export an
  optional `diagnose(task_id)` (`{:ok, detail} | :none`), consulted via
  `function_exported?/3` by the fail path to refine a failure detail.

  Implementations: `CodeLead.Executor.LocalSubprocess` (default) and
  `CodeLead.Executor.DockerContainer` (per-task opt-in via
  `tasks.execution_env`, resolved by `for_task/1`). The agent driver is
  independent of the executor.
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
  Whether `command` is runnable inside the execution environment —
  under `LocalSubprocess`, the server `PATH`. Checked before
  provisioning so a missing harness fails the run before a repository
  is cloned.
  """
  @callback available?(command :: [String.t()]) :: :ok | {:error, term()}

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

  @doc """
  The executor for a task's runs. Only repo-target tasks that opted into
  `:container` leave the default — a `:folder` target is structurally
  local, whatever its `execution_env` says.
  """
  @spec for_task(Task.t()) :: module()
  def for_task(%Task{target: :repo, execution_env: :container}) do
    CodeLead.Executor.DockerContainer
  end

  def for_task(%Task{}), do: impl()
end
