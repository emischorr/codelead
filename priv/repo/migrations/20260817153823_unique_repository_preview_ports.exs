defmodule CodeLead.Repo.Migrations.UniqueRepositoryPreviewPorts do
  use Ecto.Migration

  # Preview ports become unique across the instance: local-execution
  # previews all share the app's own host, so two repositories on one
  # port would collide there. Duplicates that predate the rule are
  # nulled (keeping the oldest row) rather than failing the migration —
  # a nulled port just disables that repo's preview until re-declared.
  def up do
    execute """
    UPDATE repositories r SET preview_port = NULL
    WHERE preview_port IS NOT NULL AND EXISTS (
      SELECT 1 FROM repositories o
      WHERE o.preview_port = r.preview_port AND o.id < r.id
    )
    """

    create unique_index(:repositories, [:preview_port], where: "preview_port IS NOT NULL")
  end

  def down do
    drop unique_index(:repositories, [:preview_port], where: "preview_port IS NOT NULL")
  end
end
