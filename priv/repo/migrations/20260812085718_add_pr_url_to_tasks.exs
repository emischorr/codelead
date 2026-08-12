defmodule CodeLead.Repo.Migrations.AddPrUrlToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :pr_url, :string
      add :pr_url_kind, :string
    end
  end
end
