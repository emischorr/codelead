defmodule CodeLead.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations) do
      add :name, :string, null: false
      add :settings, :map, null: false, default: %{}
      add :budget_limit_cents, :integer
      add :budget_limit_tokens, :bigint
      add :singleton, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create constraint(:organizations, :singleton_must_be_true, check: "singleton = true")
    create unique_index(:organizations, [:singleton])
  end
end
