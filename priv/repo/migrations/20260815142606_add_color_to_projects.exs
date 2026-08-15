defmodule CodeLead.Repo.Migrations.AddColorToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :color, :string, null: false, default: "blue"
    end
  end
end
