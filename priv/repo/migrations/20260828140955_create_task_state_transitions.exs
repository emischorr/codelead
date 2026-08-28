defmodule CodeLead.Repo.Migrations.CreateTaskStateTransitions do
  use Ecto.Migration

  def change do
    create table(:task_state_transitions) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :from_state, :string, null: false
      add :to_state, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:task_state_transitions, [:task_id])
    create index(:task_state_transitions, [:task_id, :to_state])
  end
end
