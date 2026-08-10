defmodule CodeLead.Repo.Migrations.CreatePlanningMessages do
  use Ecto.Migration

  def change do
    create table(:planning_messages) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:planning_messages, [:task_id])
  end
end
