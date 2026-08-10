defmodule CodeLead.Runtime.RunSupervisor do
  @moduledoc """
  DynamicSupervisor for active task runners, with a Registry keyed by
  task id.
  """

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
    case Registry.lookup(@registry, task_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @spec active_count() :: non_neg_integer()
  def active_count do
    Registry.count(@registry)
  end

  @spec via(pos_integer()) :: {:via, Registry, {module(), pos_integer()}}
  def via(task_id) do
    {:via, Registry, {@registry, task_id}}
  end
end
