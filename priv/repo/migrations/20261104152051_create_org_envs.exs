defmodule CodeLead.Repo.Migrations.CreateOrgEnvs do
  use Ecto.Migration

  def change do
    create table(:org_envs) do
      add :key, :string, null: false
      add :value, :binary, null: false
      add :secret, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:org_envs, ["lower(key)"], name: :org_envs_key_index)
  end
end
