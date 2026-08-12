defmodule CodeLead.Workflow.Transition do
  @moduledoc """
  One edge of a workflow, carrying the policies that decide what
  survives the move.

  `trigger` says who advances the card: `:human` for a decision,
  `:auto` for a completion signal the system acts on. `context_policy`
  governs the agent conversation (`acp_session_id`); `worktree_policy`
  governs the worktree and feature branch.

  The two policies generalise CodeLead's rework distinction: *request
  changes* is `:carry` + `:keep`, so commits accumulate on the same
  branch in the same session; *send back to planning* is `:reset` +
  `:discard`, because the spec the work was built on is being rewritten.
  """

  @type trigger :: :human | :auto
  @type context_policy :: :carry | :reset
  @type worktree_policy :: :keep | :discard

  @type t :: %__MODULE__{
          from: atom(),
          to: atom(),
          trigger: trigger(),
          context_policy: context_policy(),
          worktree_policy: worktree_policy()
        }

  @enforce_keys [:from, :to, :trigger, :context_policy, :worktree_policy]
  defstruct [:from, :to, :trigger, :context_policy, :worktree_policy]
end
