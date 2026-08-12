defmodule CodeLead.Scheduler.Gate do
  @moduledoc """
  One admission check standing between a queued task and dispatch.

  Gates compose rather than exclude: a scheduler runs an ordered list
  and the first `{:hold, reason}` wins, so a task can be subject to a
  wall clock *and* a budget at once. That is the property a single
  monolithic `admit?/1` could not express — see `CodeLead.Scheduler`.

  A hold is not an error. The task stays `run_state: :queued` with a
  badge and is re-checked on the next `CodeLead.Runtime.kick_queue/0`.
  """

  alias CodeLead.Tasks.Task

  @doc """
  May this task pass? Reasons carry data where the UI needs it — a
  hold until a known time returns that time.
  """
  @callback check(task :: Task.t()) :: :ok | {:hold, CodeLead.Scheduler.hold_reason()}
end
