defmodule CodeLead.Repo.Migrations.AddAgentAndKindToPlanningMessages do
  use Ecto.Migration

  def change do
    alter table(:planning_messages) do
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :kind, :string, null: false, default: "chat"
    end

    create index(:planning_messages, [:agent_id])
  end
end
