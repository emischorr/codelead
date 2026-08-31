defmodule CodeLead.Runtime.LiveRuns do
  @moduledoc """
  Live-process truth for every agent run on a task, backed by
  `CodeLead.Runtime.Registry` (`keys: :unique`, node-local).

  Keys encode the run *kind* — `{task_id, :execute}` for the task
  runner, `{task_id, :plan}` for the planning survey,
  `{task_id, :review, agent_id}` per reviewer — so uniqueness of the
  key is the concurrency rule: one executor, one planner, and one run
  per reviewer agent per task. No counters, no policy code. The
  registry monitors registered pids, so a crashed run unregisters
  itself.

  Kinds are stable for a run's lifetime; a task's column is not (a
  reviewer can still be live after the card leaves Review), which is
  why the key carries the kind and never the task state.
  """

  require Logger

  @registry CodeLead.Runtime.Registry

  @cancel_timeout :timer.seconds(15)

  @type advisory_kind :: :plan | {:review, pos_integer()}
  @type meta :: %{
          kind: :execute | :plan | :review,
          agent_id: pos_integer() | nil,
          agent_name: String.t() | nil,
          started_at: DateTime.t()
        }

  @doc """
  Claims the task's `kind` slot for the calling process. Registration
  is deliberately self-only: the registry monitors the pid, so a crash
  cleans up without any caller bookkeeping.
  """
  @spec register(pos_integer(), advisory_kind(), map()) :: :ok | {:error, :already_running}
  def register(task_id, kind, extra \\ %{}) do
    case Registry.register(@registry, key(task_id, kind), build_meta(kind, extra)) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_running}
    end
  end

  @doc """
  Name for the executor runner; starting a GenServer under it claims
  the `{task_id, :execute}` slot.
  """
  @spec via(pos_integer()) :: {:via, Registry, {module(), tuple(), meta()}}
  def via(task_id) do
    {:via, Registry, {@registry, key(task_id, :execute), build_meta(:execute, %{})}}
  end

  @spec lookup(pos_integer(), :execute | :plan) :: {pid(), meta()} | nil
  def lookup(task_id, kind) when kind in [:execute, :plan] do
    case Registry.lookup(@registry, key(task_id, kind)) do
      [{pid, meta}] -> {pid, meta}
      [] -> nil
    end
  end

  @doc """
  Every live run on the task, executor and advisory alike.
  """
  @spec list(pos_integer()) :: [{pid(), meta()}]
  def list(task_id) do
    Registry.select(@registry, [
      {{{task_id, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]},
      {{{task_id, :_, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  @spec planner_running?(pos_integer()) :: boolean()
  def planner_running?(task_id), do: lookup(task_id, :plan) != nil

  @spec executor_count() :: non_neg_integer()
  def executor_count do
    Registry.count_select(@registry, [{{{:_, :execute}, :_, :_}, [], [true]}])
  end

  @doc """
  Task ids with a live executor runner. This is the truth about
  *processes*, not about `run_state` — a task persisted as `:executing`
  whose id is missing here has lost its runner. Node-local, like the
  registry itself.
  """
  @spec executor_task_ids() :: [pos_integer()]
  def executor_task_ids do
    Registry.select(@registry, [{{{:"$1", :execute}, :_, :_}, [], [:"$1"]}])
  end

  @spec surveying_task_ids() :: [pos_integer()]
  def surveying_task_ids do
    Registry.select(@registry, [{{{:"$1", :plan}, :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Asks every advisory run on the task to stop and waits — bounded —
  for the processes to exit, so a worktree discarded right after
  cannot be pulled out from under a live reader. Always returns `:ok`;
  stragglers past the deadline are logged, not fatal.
  """
  @spec cancel_advisory(pos_integer()) :: :ok
  def cancel_advisory(task_id) do
    pids =
      Registry.select(@registry, [
        {{{task_id, :plan}, :"$1", :_}, [], [:"$1"]},
        {{{task_id, :review, :_}, :"$1", :_}, [], [:"$1"]}
      ])

    refs =
      for pid <- pids do
        ref = Process.monitor(pid)
        send(pid, :advisory_cancel)
        ref
      end

    await_down(refs, System.monotonic_time(:millisecond) + @cancel_timeout, task_id)
  end

  defp await_down([], _deadline, _task_id), do: :ok

  defp await_down([ref | rest] = refs, deadline, task_id) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> await_down(rest, deadline, task_id)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Logger.warning(
          "advisory runs on task #{task_id} did not stop within #{@cancel_timeout}ms"
        )

        Enum.each(refs, &Process.demonitor(&1, [:flush]))
        :ok
    end
  end

  defp key(task_id, :execute), do: {task_id, :execute}
  defp key(task_id, :plan), do: {task_id, :plan}
  defp key(task_id, {:review, agent_id}), do: {task_id, :review, agent_id}

  defp build_meta(kind, extra) do
    %{
      kind: kind_atom(kind),
      agent_id: Map.get(extra, :agent_id),
      agent_name: Map.get(extra, :agent_name),
      started_at: DateTime.utc_now()
    }
  end

  defp kind_atom({:review, _agent_id}), do: :review
  defp kind_atom(kind) when kind in [:execute, :plan], do: kind
end
