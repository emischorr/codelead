defmodule CodeLead.Repo.Migrations.BackfillMembershipsAndTaskCreators do
  use Ecto.Migration

  # Existing instances have a handful of fully trusted users: every user
  # becomes maintainer of every project (changes nothing they can do today),
  # and existing tasks are attributed to the first admin.
  def change do
    execute(
      """
      INSERT INTO project_memberships (project_id, user_id, role, inserted_at, updated_at)
      SELECT p.id, u.id, 'maintainer', NOW(), NOW()
      FROM projects p CROSS JOIN users u
      ON CONFLICT (project_id, user_id) DO NOTHING
      """,
      "DELETE FROM project_memberships WHERE role = 'maintainer'"
    )

    execute(
      """
      UPDATE tasks
      SET created_by_id = (SELECT id FROM users WHERE role = 'admin' ORDER BY id LIMIT 1)
      WHERE created_by_id IS NULL
      """,
      "SELECT 1"
    )
  end
end
