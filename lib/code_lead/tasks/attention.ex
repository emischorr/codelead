defmodule CodeLead.Tasks.Attention do
  @moduledoc """
  Embedded marker that a task needs a human: what kind, free-text
  detail, who raised it, and when. A field on the task — deliberately
  no per-user notification fan-out.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @types [:run_failed, :review_ready, :agent_question, :permission_request]

  # A question or permission request can be raised by a live executor
  # run (the human's answer is routed back to it) or by an advisory run —
  # a reviewer or the planning survey (`CodeLead.AdvisoryRun`), which has
  # no answer path and only ever times out. Only the former blocks an
  # agent from proceeding.
  @sources [:executor, :advisory]

  # The two types an agent can actually be stuck on, as opposed to
  # `:run_failed` (already stopped) or `:review_ready` (nothing running).
  @blocking_types [:agent_question, :permission_request]

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: @types
    field :detail, :string
    field :ref, :string
    field :source, Ecto.Enum, values: @sources
    field :at, :utc_datetime
  end

  @doc """
  Changeset for raising attention. `ref` carries an opaque reference back
  to the raiser (e.g. the pending permission request id).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attention, attrs) do
    attention
    |> cast(attrs, [:type, :detail, :ref, :source, :at])
    |> validate_required([:type, :source, :at])
  end

  @doc """
  Whether this attention means an agent is blocked waiting on a human
  decision — the "hand raised" case. Advisory-run escalations (a
  reviewer or the planning survey asking a question) raise the same
  types, but nothing routes an answer back to them, so they never
  actually block an agent and are excluded here.

  The single source of truth for the hand icon — every renderer of it
  should go through this rather than re-deriving the rule.
  """
  @spec blocks_agent?(t() | nil) :: boolean()
  def blocks_agent?(%__MODULE__{type: type, source: :executor}), do: type in @blocking_types
  def blocks_agent?(_other), do: false

  @doc "The attention types that can block an agent — see `blocks_agent?/1`."
  @spec blocking_types() :: [atom()]
  def blocking_types, do: @blocking_types
end
