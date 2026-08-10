defmodule CodeLead.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :hashed_password, :string
      add :role, :string, null: false, default: "member"
      add :locale, :string, null: false, default: "en"
      add :settings, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
  end
end
