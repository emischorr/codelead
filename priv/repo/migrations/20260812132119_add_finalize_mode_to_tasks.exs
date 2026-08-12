defmodule CodeLead.Repo.Migrations.AddFinalizeModeToTasks do
  use Ecto.Migration

  # Nullable on purpose: NULL means "inherit the project's default", which is
  # a different statement from any concrete mode and has to survive the
  # project default being changed later.
  def change do
    alter table(:tasks) do
      add :finalize_mode, :string
    end
  end
end
