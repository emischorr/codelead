defmodule CodeLead.Repo.Migrations.CreateProvidersAndAgents do
  use Ecto.Migration

  def change do
    create table(:providers) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :config, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:providers, [:name])

    create table(:agents) do
      add :name, :string, null: false
      add :scope, :string, null: false
      add :project_id, references(:projects, on_delete: :delete_all)
      add :roles, {:array, :string}, null: false
      add :work_type, :string, null: false
      add :driver, :string, null: false
      add :harness, :string
      add :provider_id, references(:providers, on_delete: :restrict), null: false
      add :model_variant, :string
      add :system_prompt, :text
      add :memory, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:agents, [:project_id])
    create index(:agents, [:provider_id])
    create index(:agents, [:work_type])

    create table(:project_default_reviewers) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :work_type, :string, null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_default_reviewers, [:project_id, :work_type, :agent_id])
  end
end
