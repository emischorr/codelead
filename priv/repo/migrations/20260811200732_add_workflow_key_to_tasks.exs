defmodule CodeLead.Repo.Migrations.AddWorkflowKeyToTasks do
  use Ecto.Migration

  # Names the workflow definition a task runs on. MVP registers exactly
  # one (`CodeLead.Workflow.built_in/0`), so this is a forward-compat
  # anchor: when custom workflows land, existing rows already point at
  # the built-in and no backfill is needed.
  def change do
    alter table(:tasks) do
      add :workflow_key, :string, null: false, default: "builtin.default"
    end
  end
end
