defmodule CodeLead.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :org_id, references(:organizations, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :settings, :map, null: false, default: %{}
      add :budget_limit_cents, :integer
      add :budget_limit_tokens, :bigint

      timestamps(type: :utc_datetime)
    end

    create index(:projects, [:org_id])
    create unique_index(:projects, [:name])

    create table(:repositories) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :git_url, :string, null: false
      add :default_branch, :string, null: false, default: "main"
      add :base_clone_path, :string

      timestamps(type: :utc_datetime)
    end

    create index(:repositories, [:project_id])
    create unique_index(:repositories, [:project_id, :name])

    create table(:project_envs) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :value, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_envs, [:project_id, :key])
  end
end
