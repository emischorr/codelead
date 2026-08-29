defmodule CodeLead.Repo.Migrations.AddActorColumnsToTasksAndSteps do
  use Ecto.Migration

  # Who did what: tasks remember their creator (reporter ownership checks),
  # task_steps remember the acting user on human transitions. Both nilify on
  # user deletion so history survives account removal.
  def change do
    alter table(:tasks) do
      add :created_by_id, references(:users, on_delete: :nilify_all), null: true
    end

    alter table(:task_steps) do
      add :user_id, references(:users, on_delete: :nilify_all), null: true
    end
  end
end
