defmodule CodeLead.Repo.Migrations.RemoveReadyFlagFromTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      remove :ready_flag, :boolean, default: false, null: false
    end
  end
end
