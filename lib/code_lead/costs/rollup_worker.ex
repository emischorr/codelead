defmodule CodeLead.Costs.RollupWorker do
  @moduledoc """
  Nightly Oban job: roll completed days into `daily_metrics` and prune
  old `agent_runs`.
  """

  use Oban.Worker, queue: :rollups, max_attempts: 3

  alias CodeLead.Costs

  @impl Oban.Worker
  def perform(_job) do
    Costs.rollup()
  end
end
