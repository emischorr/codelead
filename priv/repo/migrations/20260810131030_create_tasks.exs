defmodule CodeLead.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :description, :text
      add :spec, :text
      add :work_type, :string, null: false
      add :target, :string, null: false
      add :priority, :string, null: false, default: "normal"
      add :state, :string, null: false, default: "planning"
      add :run_state, :string, null: false, default: "idle"
      add :ready_flag, :boolean, null: false, default: false
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :repository_id, references(:repositories, on_delete: :nilify_all)
      add :worktree_path, :string
      add :branch_name, :string
      add :acp_session_id, :string
      add :next_prompt, :text
      add :attention, :map
      add :assignee_id, references(:users, on_delete: :nilify_all)
      add :archived_at, :utc_datetime
      add :parent_id, references(:tasks, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:project_id])
    create index(:tasks, [:project_id, :state])
    create index(:tasks, [:agent_id])
    create index(:tasks, [:repository_id])

    create table(:task_steps) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :executor_type, :string, null: false
      add :executor_name, :string, null: false
      add :executor_ref, :string
      add :kind, :string, null: false
      add :summary, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:task_steps, [:task_id])

    create table(:task_reviewers) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_reviewers, [:task_id, :agent_id])
  end
end
