defmodule CodeLead.Runtime.FinalizeReconciler do
  @moduledoc """
  Boot-time one-shot that resets finalizations a restart cut down: a
  task persisted as `run_state: :finalizing` has, by definition, no
  worker behind it anymore, so it returns to `review/idle` with a
  `:finalize_interrupted` attention telling the human what to check.

  It never retries. Pushing is idempotent from the outside; PR creation
  and merging are not, and a restart mid-push leaves the remote in a
  state only a human should judge — a blind retry could open a second
  pull request or merge twice. Transparency over magic.

  Gated by `:reconcile_finalizing_at_boot` (default `true`, `false` in
  the test env — a boot-time Repo query races the Ecto sandbox).
  """

  require Logger

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  # Blocking on purpose: the reset must land before anything serves a
  # stale "finalizing" state. Returns :ignore — nothing stays running.
  @spec start_link() :: :ignore
  def start_link do
    if Application.get_env(:code_lead, :reconcile_finalizing_at_boot, true), do: run()
    :ignore
  end

  @spec run() :: :ok
  def run do
    case CodeLead.Tasks.interrupt_finalizing() do
      0 ->
        :ok

      count ->
        Logger.warning(
          "finalize reconciliation: #{count} interrupted finalization(s) flagged for review"
        )
    end

    :ok
  rescue
    error ->
      Logger.error("finalize reconciliation failed: #{Exception.message(error)}")
      :ok
  end
end
