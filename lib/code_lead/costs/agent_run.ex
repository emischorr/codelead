defmodule CodeLead.Costs.AgentRun do
  @moduledoc """
  Per-execution usage record (executor and reviewer runs alike).
  Prunable after ~14 days — permanent numbers live in `daily_metrics`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "agent_runs" do
    field :task_id, :id
    field :task_step_id, :id
    field :agent_id, :id
    field :provider_id, :id
    field :prompt_tokens, :integer, default: 0
    field :completion_tokens, :integer, default: 0
    field :total_tokens, :integer, default: 0
    field :cost_cents, :integer, default: 0
    field :status, Ecto.Enum, values: [:ok, :error, :cancelled]
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
