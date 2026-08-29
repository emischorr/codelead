defmodule CodeLead.Repo.Migrations.AddSecretToProjectEnvs do
  use Ecto.Migration

  def change do
    alter table(:project_envs) do
      add :secret, :boolean, null: false, default: true
    end
  end
end
