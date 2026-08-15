defmodule CodeLead.Repo.Migrations.AddContainerExecutionSeams do
  use Ecto.Migration

  # Dormant seams for the container executor (ADR-0003). Nothing reads
  # them yet; defaults make every existing row valid.
  def change do
    alter table(:repositories) do
      add :env_kind, :string, null: false, default: "default"
      add :devcontainer_path, :string
      add :image_ref, :string
      add :dockerfile, :string
    end

    alter table(:tasks) do
      add :execution_env, :string, null: false, default: "local"
    end

    alter table(:agents) do
      add :tool_features, {:array, :string}, null: false, default: []
    end
  end
end
