defmodule CodeLead.Repo.Migrations.AddRunMetaToAgentRuns do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :cached_read_tokens, :bigint, null: false, default: 0
      add :cached_write_tokens, :bigint, null: false, default: 0
      add :reasoning_tokens, :bigint, null: false, default: 0

      # Wall-clock milliseconds from a monotonic clock. started_at /
      # finished_at are second-granular and skew with the system clock,
      # so they anchor the timeline while this carries the duration.
      add :duration_ms, :integer
    end
  end
end
