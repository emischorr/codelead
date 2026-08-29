defmodule CodeLead.Repo.Migrations.AddDefaultProjectBudgetsToOrganizations do
  use Ecto.Migration

  # Copied onto each new project at creation; nil = no limit. Changing the
  # default later does not touch existing projects.
  def change do
    alter table(:organizations) do
      add :default_project_budget_limit_cents, :integer, null: true
      add :default_project_budget_limit_tokens, :bigint, null: true
    end
  end
end
