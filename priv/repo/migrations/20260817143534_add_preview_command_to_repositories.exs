defmodule CodeLead.Repo.Migrations.AddPreviewCommandToRepositories do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :preview_command, :string
    end
  end
end
