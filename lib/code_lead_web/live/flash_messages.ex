defmodule CodeLeadWeb.FlashMessages do
  @moduledoc """
  Maps context error reasons to human-readable flash messages: workflow
  transitions for the board and task LiveViews, and the guarded-delete
  refusals for the settings pages.
  """

  alias CodeLead.Git

  @spec transition_error(term()) :: String.t()
  def transition_error(:invalid_state),
    do: "That action isn't available in the task's current state."

  def transition_error(:no_executor),
    do: "Select an executor agent before starting the run."

  def transition_error(:executor_ineligible),
    do: "The selected executor isn't eligible for this task's work type."

  def transition_error(:missing_repository),
    do: "Link a repository before starting a repo-targeted task."

  def transition_error(:missing_execution_env),
    do:
      "This task is set to run in a container, but its repository doesn't declare " <>
        "a container image. Set one under Settings → Project → Repositories, or " <>
        "switch the task's execution back to Local."

  def transition_error(:unlicensed_execution_env),
    do:
      "Container execution requires a commercial license. Switch this task's " <>
        "execution back to Local, or set a LICENSE_KEY that grants it."

  def transition_error(other), do: "Action failed: #{inspect(other)}"

  @doc """
  Explains why Approve → Done could not finalize the work product, in
  terms of what the operator has to change.
  """
  @spec finalize_error(term()) :: String.t()
  def finalize_error(:invalid_state), do: transition_error(:invalid_state)

  def finalize_error(
        {:push_failed, {:remote, %{output: output, forge: forge, token_present?: present?}}}
      ) do
    "Could not finalize — " <> Git.remote_failure("push the branch", output, forge, present?)
  end

  def finalize_error({:push_failed, :no_worktree}),
    do: "This task has no worktree to push. Send it back to Planning and run it again."

  def finalize_error({:push_failed, :no_branch}),
    do: "This task has no feature branch to push. Send it back to Planning and run it again."

  def finalize_error({:push_failed, :worktree_missing}),
    do:
      "The task's worktree is gone from disk, so there is nothing to push. " <>
        "Send it back to Planning and run it again."

  def finalize_error(
        {:merge_failed,
         {:remote, %{output: output, forge: forge, token_present?: present?, base_branch: base}}}
      ) do
    "Could not finalize — " <> Git.merge_failure(base, output, forge, present?)
  end

  # A merge pushes the feature branch before it merges, so every way the
  # push itself can fail reaches here too — with the same remedies.
  def finalize_error({:merge_failed, reason}), do: finalize_error({:push_failed, reason})

  def finalize_error(:no_artifact),
    do: "The task folder is empty — there is no artifact to hand over."

  def finalize_error(:no_artifact_repository),
    do:
      "This task finalizes by committing its artifact to a repository, but none is linked. " <>
        "Pick one in the Target card, or switch the finalize mode to Artifact."

  def finalize_error(other), do: "Finalization failed: #{inspect(other)}"

  @doc """
  Explains why a repo-aware planning survey could not start.
  """
  @spec survey_error(term()) :: String.t()
  def survey_error(:no_planner),
    do: "No planning agent is configured for this task's work type."

  def survey_error(:not_repo_aware),
    do: "Only an ACP planning agent can survey a repository. Pick one to run a survey."

  def survey_error(:planner_ineligible),
    do: "The selected planning agent isn't eligible for this task's work type."

  def survey_error(:missing_repository),
    do: "Link a repository before running a repo survey."

  def survey_error(other), do: "Survey failed to start: #{inspect(other)}"

  @doc """
  Explains why a guarded delete was refused, and what to clear first.
  """
  @spec delete_error(term()) :: String.t()
  def delete_error(:last_user),
    do: "This is the last user — deleting it would lock everyone out of the instance."

  def delete_error({:in_use, names}) when is_list(names),
    do: "Still used by #{Enum.join(names, ", ")}. Point those agents at another provider first."

  def delete_error({:in_use, %{} = usage}) do
    "Still referenced by #{usage_summary(usage)}. Clear those first."
  end

  def delete_error({:has_tasks, 1}),
    do: "1 task still references this. Delete or archive it first."

  def delete_error({:has_tasks, count}),
    do: "#{count} tasks still reference this. Delete or archive them first."

  def delete_error(:not_deletable),
    do: "This task can no longer be deleted — it has left Planning."

  def delete_error(other), do: "Delete failed: #{inspect(other)}"

  defp usage_summary(usage) do
    [
      {usage[:tasks], "task", "tasks"},
      {usage[:reviewer_slots], "task reviewer slot", "task reviewer slots"},
      {usage[:default_reviewer_slots], "default reviewer slot", "default reviewer slots"}
    ]
    |> Enum.reject(fn {count, _one, _many} -> count in [nil, 0] end)
    |> Enum.map_join(", ", fn
      {1, one, _many} -> "1 #{one}"
      {count, _one, many} -> "#{count} #{many}"
    end)
  end
end
