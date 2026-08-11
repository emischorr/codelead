defmodule CodeLead.Repo.Migrations.CreateAgentEvents do
  use Ecto.Migration

  def change do
    create table(:agent_events) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :task_step_id, references(:task_steps, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :text, :text
      add :external_id, :string
      add :streaming, :boolean, null: false, default: false
      add :data, :map, null: false, default: %{}

      # updated_at is kept (unlike planning_messages): tool-call rows and the
      # open message row are updated in place as the run progresses.
      timestamps(type: :utc_datetime)
    end

    create index(:agent_events, [:task_id])

    # toolCallIds are only unique per ACP session, and a task resumes across
    # runs, so the dedup key is scoped to the run's step.
    create unique_index(:agent_events, [:task_step_id, :external_id],
             where: "external_id IS NOT NULL"
           )
  end
end
