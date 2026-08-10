defmodule CodeLead.Repo.Migrations.CreateReviews do
  use Ecto.Migration

  def change do
    create table(:reviews) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :task_step_id, references(:task_steps, on_delete: :nilify_all)
      add :cycle, :integer, null: false
      add :verdict, :string
      add :findings, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:reviews, [:task_id, :cycle])
  end
end
