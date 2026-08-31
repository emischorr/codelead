defmodule CodeLead.Runtime.RunSupervisor do
  @moduledoc """
  DynamicSupervisor for active task runners. The Registry it declares
  is keyed by `{task_id, kind[, agent_id]}` and shared with advisory
  runs — `CodeLead.Runtime.LiveRuns` owns the key shape; the helpers
  here are executor-only views of it.
  """

  alias CodeLead.Runtime.LiveRuns
  alias CodeLead.Runtime.TaskRunner

  @registry CodeLead.Runtime.Registry

  @spec child_specs() :: [Supervisor.child_spec() | {module(), term()}]
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: __MODULE__, strategy: :one_for_one}
    ]
  end

  @spec start_runner(pos_integer()) :: {:ok, pid()} | {:error, term()}
  def start_runner(task_id) do
    case DynamicSupervisor.start_child(__MODULE__, {TaskRunner, task_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @spec whereis(pos_integer()) :: pid() | nil
  def whereis(task_id) do
    case LiveRuns.lookup(task_id, :execute) do
      {pid, _meta} -> pid
      nil -> nil
    end
  end

  @spec via(pos_integer()) :: {:via, Registry, {module(), tuple(), LiveRuns.meta()}}
  def via(task_id), do: LiveRuns.via(task_id)
end
