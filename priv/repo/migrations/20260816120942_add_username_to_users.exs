defmodule CodeLead.Repo.Migrations.AddUsernameToUsers do
  use Ecto.Migration

  # A window-function de-dup only guards collisions *within* one candidate
  # group (e.g. two "jane@..." addresses) — it can't see that "jane@other"'s
  # suffixed "jane2" collides with "jane+2@..."'s own natural candidate
  # "jane2". Row-by-row, checking against every username assigned so far
  # (including earlier in this same loop), is the only way to guarantee
  # global uniqueness against arbitrary historical data.
  @backfill """
  DO $$
  DECLARE
    r RECORD;
    candidate citext;
    suffix INT;
    final_username citext;
  BEGIN
    FOR r IN SELECT id, email FROM users ORDER BY id LOOP
      candidate := NULLIF(
        regexp_replace(split_part(r.email, '@', 1), '[^a-zA-Z0-9_.-]', '', 'g'),
        ''
      );
      IF candidate IS NULL THEN
        candidate := 'user' || r.id;
      END IF;

      final_username := candidate;
      suffix := 1;
      WHILE EXISTS (SELECT 1 FROM users WHERE username = final_username) LOOP
        suffix := suffix + 1;
        final_username := candidate || suffix;
      END LOOP;

      UPDATE users SET username = final_username WHERE id = r.id;
    END LOOP;
  END $$;
  """

  def change do
    alter table(:users) do
      add :username, :citext
    end

    execute(@backfill, "")

    execute(
      "ALTER TABLE users ALTER COLUMN username SET NOT NULL",
      "ALTER TABLE users ALTER COLUMN username DROP NOT NULL"
    )

    execute(
      "ALTER TABLE users ALTER COLUMN email DROP NOT NULL",
      "ALTER TABLE users ALTER COLUMN email SET NOT NULL"
    )

    create unique_index(:users, [:username])
  end
end
