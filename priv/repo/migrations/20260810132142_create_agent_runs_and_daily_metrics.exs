defmodule CodeLead.Repo.Migrations.CreateAgentRunsAndDailyMetrics do
  use Ecto.Migration

  def change do
    create table(:agent_runs) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :task_step_id, references(:task_steps, on_delete: :nilify_all)
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :provider_id, references(:providers, on_delete: :nilify_all)
      add :prompt_tokens, :bigint, null: false, default: 0
      add :completion_tokens, :bigint, null: false, default: 0
      add :total_tokens, :bigint, null: false, default: 0
      add :cost_cents, :integer, null: false, default: 0
      add :status, :string, null: false
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:agent_runs, [:task_id])
    create index(:agent_runs, [:started_at])

    create table(:daily_metrics) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :date, :date, null: false
      add :total_tokens, :bigint, null: false, default: 0
      add :cost_cents, :bigint, null: false, default: 0
      add :run_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:daily_metrics, [:project_id, :date])
  end
end
