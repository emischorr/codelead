defmodule CodeLead.Workspace do
  @moduledoc """
  Path layout of the CodeLead-managed workspace volume:

      <root>/repos/<name>-<id>/   base clone per linked repository
      <root>/worktrees/task-<id>/ git worktree per :repo-target task
      <root>/tasks/<id>/          task folder per :folder-target task
  """

  @spec root() :: String.t()
  def root do
    Application.fetch_env!(:code_lead, :workspace_root)
  end

  @spec base_clone_path(String.t(), pos_integer()) :: String.t()
  def base_clone_path(repository_name, repository_id) do
    Path.join([root(), "repos", "#{sanitize(repository_name)}-#{repository_id}"])
  end

  @spec worktree_path(pos_integer()) :: String.t()
  def worktree_path(task_id) do
    Path.join([root(), "worktrees", "task-#{task_id}"])
  end

  @spec task_folder(pos_integer()) :: String.t()
  def task_folder(task_id) do
    Path.join([root(), "tasks", Integer.to_string(task_id)])
  end

  @doc """
  Filesystem/branch-safe slug from a free-text title.
  """
  @spec slug(String.t()) :: String.t()
  def slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "task"
      slug -> String.trim(slug, "-")
    end
  end

  defp sanitize(name), do: slug(name)
end
