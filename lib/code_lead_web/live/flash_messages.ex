defmodule CodeLeadWeb.FlashMessages do
  @moduledoc """
  Maps `CodeLead.Tasks.transition_error/0` reasons to human-readable
  flash messages, shared by the board and task LiveViews.
  """

  @spec transition_error(term()) :: String.t()
  def transition_error(:invalid_state),
    do: "That action isn't available in the task's current state."

  def transition_error(:no_executor),
    do: "Select an executor agent before starting the run."

  def transition_error(:executor_ineligible),
    do: "The selected executor isn't eligible for this task's work type."

  def transition_error(:missing_repository),
    do: "Link a repository before starting a repo-targeted task."

  def transition_error(other), do: "Action failed: #{inspect(other)}"
end
