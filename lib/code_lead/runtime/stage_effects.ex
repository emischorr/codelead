defmodule CodeLead.Runtime.StageEffects do
  @moduledoc """
  What entering a stage *does*, dispatched on
  `CodeLead.Workflow.Stage` type rather than on column identity. The
  only place in the runtime that maps a stage to behaviour.

  Two hooks, because one of them has to be able to veto:

  - `prepare/2` runs **before** the state is written and may return
    `{:error, reason}` to abort the transition. `:finalize` uses it —
    a push that fails must leave the task in Review rather than land it
    in Done with nothing pushed.
  - `on_enter/3` runs **after** the write, receiving whatever
    `prepare/2` produced. This is where work starts: dispatching the
    agent, fanning out reviewers.

  `:plan` and `:custom` do nothing. `:custom` is the default stage type,
  so a future column added without an implementation here is inert
  rather than dangerous.
  """

  alias CodeLead.Reviews
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Runtime.ScheduledDispatchWorker
  alias CodeLead.Scheduler
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Workflow.Stage

  @doc """
  Pre-commit hook. `{:error, reason}` aborts the transition before
  anything is written.
  """
  @spec prepare(Stage.stage_type(), Task.t()) :: {:ok, term()} | {:error, term()}
  def prepare(:finalize, %Task{} = task), do: CodeLead.Finalizer.finalize(task)

  def prepare(_stage_type, %Task{}), do: {:ok, nil}

  @doc """
  Post-commit hook, given the task as written and the value `prepare/2`
  produced. Its result is not part of the transition's outcome — the
  task has already moved.
  """
  @spec on_enter(Stage.stage_type(), Task.t(), term()) :: term()
  def on_enter(:execute, %Task{} = task, _prepared), do: try_dispatch(task)

  def on_enter(:review, %Task{} = task, _prepared) do
    {:ok, _cycle} = Reviews.start_cycle(task)
    :ok
  end

  def on_enter(:finalize, %Task{} = task, %{note: note}) do
    Tasks.record_step(task.id, :commit, :system, "finalizer", note)
    :ok
  end

  def on_enter(_stage_type, %Task{}, _prepared), do: :ok

  @doc """
  Asks the scheduler to admit the task and dispatches it if so. A hold
  (over budget, at capacity) is not an error: the task stays queued
  with its badge and the next `CodeLead.Runtime.kick_queue/0` retries.

  A hold on a start time is the one that cannot wait for a passing
  kick, so it books its own wake-up. This is the single `admit?/1`
  call site, so every route into the queued state — a fresh start, a
  rework, a retry, a queue kick — is covered by that one line.
  """
  @spec try_dispatch(Task.t()) :: {:ok, pid()} | {:error, term()} | :hold | nil
  def try_dispatch(%Task{} = task) do
    if RunSupervisor.whereis(task.id) == nil do
      case Scheduler.impl().admit?(task) do
        :ok ->
          Scheduler.impl().dispatch(task)

        {:hold, {:scheduled, at}} ->
          {:ok, _job} = ScheduledDispatchWorker.ensure_enqueued(task.id, at)
          :hold

        {:hold, _reason} ->
          :hold
      end
    end
  end
end
