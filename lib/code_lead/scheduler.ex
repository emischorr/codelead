defmodule CodeLead.Scheduler do
  @moduledoc """
  Behaviour for admitting and dispatching queued task runs. Bound to
  the task's provider connection, not global.

  MVP implementation: `PassThrough` (admit unless over budget or over
  the concurrency cap, dispatch immediately). Later: `Windowed` (hold
  for subscription token-window resets).
  """

  alias CodeLead.Tasks.Task

  @doc """
  May this queued task start now? `{:hold, reason}` keeps it queued
  (shown as a badge in the Running column).
  """
  @callback admit?(task :: Task.t()) :: :ok | {:hold, atom()}

  @doc """
  Starts the run (a `TaskRunner` process).
  """
  @callback dispatch(task :: Task.t()) :: {:ok, pid()} | {:error, term()}

  @spec impl() :: module()
  def impl do
    Application.get_env(:code_lead, :scheduler, CodeLead.Scheduler.PassThrough)
  end
end
