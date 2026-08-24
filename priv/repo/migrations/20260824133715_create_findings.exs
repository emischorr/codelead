defmodule CodeLead.Repo.Migrations.CreateFindings do
  use Ecto.Migration

  # One row per itemized survey (later: review) finding. Agent-side
  # observation (`observed`, `*_seen_step_id`) and human-side resolution
  # (`resolution*`) are deliberately separate column groups: a later
  # agent run may bump the observation but never touches a resolution.
  def change do
    create table(:findings) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :phase, :string, null: false
      add :first_seen_step_id, references(:task_steps, on_delete: :nilify_all)
      add :last_seen_step_id, references(:task_steps, on_delete: :nilify_all)
      add :agent_id, references(:agents, on_delete: :nilify_all)

      add :severity, :string, null: false
      add :title, :string, null: false
      add :body, :text
      add :paths, {:array, :string}, null: false, default: []

      add :observed, :string, null: false, default: "open"

      add :resolution, :string
      add :resolution_note, :text
      add :resolved_by_id, references(:users, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:findings, [:task_id, :phase])
  end
end
