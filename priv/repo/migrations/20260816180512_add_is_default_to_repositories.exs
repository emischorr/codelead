defmodule CodeLead.Repo.Migrations.AddIsDefaultToRepositories do
  use Ecto.Migration

  def up do
    alter table(:repositories) do
      add :is_default, :boolean, null: false, default: false
    end

    # Backfill: the first repository linked to each project (by insertion
    # order) becomes its default, matching the behavior the app already
    # had before this column existed.
    execute """
    UPDATE repositories
    SET is_default = true
    WHERE id IN (
      SELECT DISTINCT ON (project_id) id
      FROM repositories
      ORDER BY project_id, id
    )
    """

    create unique_index(:repositories, [:project_id],
             where: "is_default = true",
             name: :repositories_project_id_is_default_index
           )
  end

  def down do
    drop_if_exists(
      unique_index(:repositories, [:project_id], name: :repositories_project_id_is_default_index)
    )

    alter table(:repositories) do
      remove :is_default
    end
  end
end
