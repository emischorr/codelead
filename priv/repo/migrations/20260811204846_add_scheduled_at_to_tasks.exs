defmodule CodeLead.Repo.Migrations.AddScheduledAtToTasks do
  use Ecto.Migration

  # When a queued run may start. `NULL` means "as soon as the scheduler
  # admits it", which is every task created before this migration.
  # Deliberately unindexed: nothing queries on it — the value is read
  # per row by `CodeLead.Scheduler.Gates.ScheduleGate`.
  def change do
    alter table(:tasks) do
      add :scheduled_at, :utc_datetime
    end
  end
end
