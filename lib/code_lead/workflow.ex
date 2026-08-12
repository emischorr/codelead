defmodule CodeLead.Workflow do
  @moduledoc """
  The declarative workflow definition the state machine runs on.

  A `%Workflow{}` is a set of `Stage`s and the `Transition`s between
  them. `CodeLead.Tasks` derives every field change from the edge and
  the target stage; `CodeLead.Runtime` dispatches side effects on the
  target stage's `stage_type`. Neither knows the column names.

  MVP ships exactly one definition, `built_in/0`, written here in code
  and reproducing architecture spec §4 1:1. `tasks.workflow_key` names
  it per task. The struct is the stable seam: custom workflows land as
  a persistence + loader layer that produces the *same* struct from the
  database, and the machine will not care where it came from.

  **MVP boundary.** `tasks.state` is still a fixed Ecto enum and the
  definition still lives in code. Generalising `state` into a stage
  reference, and loading the struct from the database, is the known
  future migration. There is deliberately no reachability or cycle
  validator: with one hand-written definition it would guard nothing,
  and it belongs to the deferred feature.
  """

  alias CodeLead.Workflow.Stage
  alias CodeLead.Workflow.Transition

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          stages: [Stage.t()],
          transitions: [Transition.t()]
        }

  @enforce_keys [:key, :name, :stages, :transitions]
  defstruct [:key, :name, :stages, :transitions]

  @builtin_key "builtin.default"

  @doc """
  The key of the built-in workflow — the default for every task.
  """
  @spec builtin_key() :: String.t()
  def builtin_key, do: @builtin_key

  @doc """
  CodeLead's four-column workflow: Planning → Running → Review → Done.

  Only `running → review` is automatic; every other edge is a human
  handoff. `:cancelled` is a terminal task state, not a stage.
  """
  @spec built_in() :: t()
  def built_in do
    %__MODULE__{
      key: @builtin_key,
      name: "CodeLead default",
      stages: [
        %Stage{key: :planning, name: "Planning", position: 1, stage_type: :plan},
        %Stage{key: :running, name: "Running", position: 2, stage_type: :execute},
        %Stage{key: :review, name: "Review", position: 3, stage_type: :review},
        %Stage{key: :done, name: "Done", position: 4, stage_type: :finalize}
      ],
      transitions: [
        # Start: the human decides the spec is ready.
        %Transition{
          from: :planning,
          to: :running,
          trigger: :human,
          context_policy: :carry,
          worktree_policy: :keep
        },
        # The one completion signal — not a decision.
        %Transition{
          from: :running,
          to: :review,
          trigger: :auto,
          context_policy: :carry,
          worktree_policy: :keep
        },
        # Cancel: the worktree stays for inspection.
        %Transition{
          from: :running,
          to: :planning,
          trigger: :human,
          context_policy: :carry,
          worktree_policy: :keep
        },
        # Approve.
        %Transition{
          from: :review,
          to: :done,
          trigger: :human,
          context_policy: :carry,
          worktree_policy: :keep
        },
        # Request changes: same session, same branch, commits accumulate.
        %Transition{
          from: :review,
          to: :running,
          trigger: :human,
          context_policy: :carry,
          worktree_policy: :keep
        },
        # Send back to planning: the spec is being rewritten, so the
        # context built on it is dropped rather than carried forward.
        %Transition{
          from: :review,
          to: :planning,
          trigger: :human,
          context_policy: :reset,
          worktree_policy: :discard
        }
      ]
    }
  end

  @doc """
  Resolves a workflow by key. Raises on an unknown key — MVP registers
  only the built-in.
  """
  @spec fetch!(String.t()) :: t()
  def fetch!(@builtin_key), do: built_in()

  def fetch!(key), do: raise(ArgumentError, "unknown workflow key #{inspect(key)}")

  @doc """
  The stage with the given key, or nil.
  """
  @spec stage(t(), atom()) :: Stage.t() | nil
  def stage(%__MODULE__{stages: stages}, key), do: Enum.find(stages, &(&1.key == key))

  @doc """
  The edge between two stages. `:error` means the move is not part of
  this workflow — the caller reports an invalid transition.
  """
  @spec fetch_transition(t(), atom(), atom()) :: {:ok, Transition.t()} | :error
  def fetch_transition(%__MODULE__{transitions: transitions}, from, to) do
    case Enum.find(transitions, &(&1.from == from and &1.to == to)) do
      nil -> :error
      transition -> {:ok, transition}
    end
  end

  @doc """
  Every edge leaving a stage.
  """
  @spec outgoing(t(), atom()) :: [Transition.t()]
  def outgoing(%__MODULE__{transitions: transitions}, from) do
    Enum.filter(transitions, &(&1.from == from))
  end
end
