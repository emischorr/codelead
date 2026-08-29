defmodule CodeLead.Repo.Migrations.CreateProjectMemberships do
  use Ecto.Migration

  # Project-level roles: reporter < member < maintainer. One row per
  # (project, user); admins bypass membership entirely and have no rows.
  def change do
    create table(:project_memberships) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_memberships, [:project_id, :user_id])
    create index(:project_memberships, [:user_id])
  end
end
