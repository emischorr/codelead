defmodule CodeLead.Repo.Migrations.AddPreviewPortToRepositories do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :preview_port, :integer
    end
  end
end
