defmodule CodeLead.Findings.Finding do
  @moduledoc """
  One itemized, severity-labelled observation from an advisory run —
  today only planning surveys (`phase: :planning`); reviews reuse the
  same table in a later iteration.

  Two independently owned column groups:

  - **Agent observation** — `observed` plus `first_seen_step_id` /
    `last_seen_step_id`. A later run may reclassify a finding as
    `:resolved` or `:not_applicable`, but only via
    `CodeLead.Findings.apply_report/5`.
  - **Human resolution** — `resolution`, `resolution_note`,
    `resolved_by_id`, `resolved_at`. Set only by a human (or the
    console); never written or cleared by an agent run.

  What the row *displays* as is derived from both groups by
  `display_state/1`, not stored.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeLead.Accounts.User
  alias CodeLead.Agents.Agent

  @type t :: %__MODULE__{}

  @title_limit 120

  schema "findings" do
    field :task_id, :id
    field :phase, Ecto.Enum, values: [:planning, :review]
    field :first_seen_step_id, :id
    field :last_seen_step_id, :id

    field :severity, Ecto.Enum, values: [:high, :medium, :low]
    field :title, :string
    field :body, :string
    field :paths, {:array, :string}, default: []

    field :observed, Ecto.Enum,
      values: [:open, :resolved, :not_applicable],
      default: :open

    field :resolution, Ecto.Enum, values: [:addressed, :dismissed]
    field :resolution_note, :string
    field :resolved_at, :utc_datetime

    belongs_to :agent, Agent
    belongs_to :resolved_by, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Collapses observation and resolution into what the row renders as.
  A human resolution always wins over the agent's observation.
  """
  @spec display_state(t()) :: :open | :addressed | :dismissed | :obsolete
  def display_state(%__MODULE__{resolution: :addressed}), do: :addressed
  def display_state(%__MODULE__{resolution: :dismissed}), do: :dismissed
  def display_state(%__MODULE__{observed: :not_applicable}), do: :obsolete
  def display_state(%__MODULE__{}), do: :open

  @doc """
  True when the agent considers an unresolved finding handled — the
  human confirms by ticking; the checkbox is never auto-ticked.
  """
  @spec agent_resolved?(t()) :: boolean()
  def agent_resolved?(%__MODULE__{resolution: nil, observed: :resolved}), do: true
  def agent_resolved?(%__MODULE__{}), do: false

  @doc """
  True when a run *after* the human's resolution still flags the
  finding. The resolution stands; the UI shows a subtle marker. A run
  that merely predates the resolution proves nothing, so the marker
  needs the latest step to postdate `resolved_at`.
  """
  @spec still_flagged?(t(), struct() | nil) :: boolean()
  def still_flagged?(%__MODULE__{}, nil), do: false

  def still_flagged?(%__MODULE__{} = finding, latest_step) do
    finding.resolution != nil and finding.observed == :open and
      finding.last_seen_step_id == latest_step.id and
      DateTime.compare(finding.resolved_at, latest_step.inserted_at) == :lt
  end

  @spec title_limit() :: pos_integer()
  def title_limit, do: @title_limit

  @doc """
  Changeset for the human-owned resolution fields; the note is the only
  free-text user input on the row.
  """
  @spec resolution_changeset(t(), map()) :: Ecto.Changeset.t()
  def resolution_changeset(%__MODULE__{} = finding, attrs) do
    finding
    |> cast(attrs, [:resolution, :resolution_note, :resolved_at])
    |> validate_required([:resolution, :resolved_at])
  end
end
