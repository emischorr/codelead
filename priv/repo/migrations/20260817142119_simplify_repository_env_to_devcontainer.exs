defmodule CodeLead.Repo.Migrations.SimplifyRepositoryEnvToDevcontainer do
  use Ecto.Migration

  # Devcontainer becomes the one container execution path (ADR-0009):
  # `image` rows keep their "this repo runs in containers" intent by
  # mapping to `devcontainer` — the old image_ref belongs in the repo's
  # devcontainer.json as `"image":` from now on.
  def up do
    execute "UPDATE repositories SET env_kind = 'devcontainer' WHERE env_kind IN ('image', 'dockerfile')"

    alter table(:repositories) do
      remove :image_ref
      remove :dockerfile
    end
  end

  def down do
    alter table(:repositories) do
      add :image_ref, :string
      add :dockerfile, :string
    end
  end
end
