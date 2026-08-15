defmodule CodeLead.Agents.Agent do
  @moduledoc """
  A reusable worker persona: role(s), work type, driver, provider +
  model, and system prompt. Lives at org level (shared) or project
  level. `memory` is a schema seam, unused in MVP logic.

  A role is the *slot* the agent fills — `:execute`, `:review`, or
  `:plan` — and is independent of the driver, which decides what the
  agent can do in that slot. A `:plan` agent on `:llm_api` refines the
  spec from text alone; the same role on `:acp` surveys the repository
  read-only. See `CodeLead.Planning`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeLead.Agents.Provider

  @type t :: %__MODULE__{}

  @roles [:execute, :review, :plan]
  @work_types [:code, :design, :content, :file]

  schema "agents" do
    field :name, :string
    field :scope, Ecto.Enum, values: [:org, :project], default: :org
    field :project_id, :id
    field :roles, {:array, Ecto.Enum}, values: @roles
    field :work_type, Ecto.Enum, values: @work_types
    field :driver, Ecto.Enum, values: [:acp, :llm_api]
    field :harness, Ecto.Enum, values: [:claude_code, :codex]
    field :model_variant, :string
    field :system_prompt, :string
    field :memory, :map, default: %{}

    belongs_to :provider, Provider

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating an agent. `project_id` binds it to
  one project; leaving it blank (with `scope: :org`) keeps it selectable
  everywhere — see `validate_scope/1`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :scope,
      :project_id,
      :roles,
      :work_type,
      :driver,
      :harness,
      :provider_id,
      :model_variant,
      :system_prompt,
      :memory
    ])
    |> validate_required([:name, :scope, :roles, :work_type, :driver, :provider_id])
    |> validate_length(:roles, min: 1)
    |> validate_harness()
    |> validate_scope()
    |> foreign_key_constraint(:provider_id)
    |> foreign_key_constraint(:project_id)
  end

  defp validate_harness(changeset) do
    case {get_field(changeset, :driver), get_field(changeset, :harness)} do
      {:acp, nil} ->
        add_error(changeset, :harness, "is required for the acp driver")

      {:llm_api, harness} when not is_nil(harness) ->
        add_error(changeset, :harness, "must be empty for the llm_api driver")

      _valid ->
        changeset
    end
  end

  defp validate_scope(changeset) do
    case {get_field(changeset, :scope), get_field(changeset, :project_id)} do
      {:project, nil} ->
        add_error(changeset, :project_id, "is required for project scope")

      {:org, project_id} when not is_nil(project_id) ->
        add_error(changeset, :project_id, "must be empty for org scope")

      _valid ->
        changeset
    end
  end
end
