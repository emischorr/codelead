defmodule CodeLead.Repo.Migrations.AddCompletedAtToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :completed_at, :utc_datetime
    end

    # Every dashboard query filters on `completed_at IS NOT NULL`, and most
    # tasks never reach Done — the partial index stays small.
    create index(:tasks, [:completed_at], where: "completed_at IS NOT NULL")

    # The app has never been deployed, so every existing Done row is demo
    # data and `updated_at` is the closest approximation of an approval time
    # it has. Saves a database reset; deliberately inexact.
    execute "UPDATE tasks SET completed_at = updated_at WHERE state = 'done'", ""
  end
end
