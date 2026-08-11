defmodule CodeLeadWeb.FlashMessages do
  @moduledoc """
  Maps context error reasons to human-readable flash messages: workflow
  transitions for the board and task LiveViews, and the guarded-delete
  refusals for the settings pages.
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
