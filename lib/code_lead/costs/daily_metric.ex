defmodule CodeLead.Costs.DailyMetric do
  @moduledoc """
  Permanent per-project per-day rollup of `agent_runs`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "daily_metrics" do
    field :project_id, :id
    field :date, :date
    field :total_tokens, :integer, default: 0
    field :cost_cents, :integer, default: 0
    field :run_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
