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

  @doc """
  The task ids that currently have a runner process. This is the truth
  about *processes*, not about `run_state` — a task persisted as
  `:executing` whose id is missing here has lost its runner. Node-local,
  like the registry itself.
  """
  @spec active_task_ids() :: [pos_integer()]
  def active_task_ids do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @spec via(pos_integer()) :: {:via, Registry, {module(), pos_integer()}}
  def via(task_id) do
    {:via, Registry, {@registry, task_id}}
  end
end
