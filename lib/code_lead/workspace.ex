defmodule CodeLead.Workspace do
  @moduledoc """
  Path layout of the CodeLead-managed workspace volume:

      <root>/repos/<name>-<id>/   base clone per linked repository
      <root>/worktrees/task-<id>/ git worktree per :repo-target task
      <root>/tasks/<id>/          task folder per :folder-target task
      <root>/surveys/task-<id>/   disposable read-only planning survey
      <root>/merges/task-<id>/    disposable worktree a Done merge runs in
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

  @doc """
  Where a planning survey checks out default-branch source. Separate
  from `worktree_path/1` so a survey can never be mistaken for — or
  collide with — the task's execution worktree.
  """
  @spec survey_worktree_path(pos_integer()) :: String.t()
  def survey_worktree_path(task_id) do
    Path.join([root(), "surveys", "task-#{task_id}"])
  end

  @doc """
  Where a Done merge stages the default branch before pushing it.
  Separate from `worktree_path/1` for the same reason a survey is: it is
  disposable, and deleting it must never touch the task's own worktree.
  """
  @spec merge_worktree_path(pos_integer()) :: String.t()
  def merge_worktree_path(task_id) do
    Path.join([root(), "merges", "task-#{task_id}"])
  end

  @spec task_folder(pos_integer()) :: String.t()
  def task_folder(task_id) do
    Path.join([root(), "tasks", Integer.to_string(task_id)])
  end

  @doc """
  The regular files a folder holds, relative to it. A symlink or a
  socket an agent left behind has nothing to contribute to an artifact
  and would only fail the read.

  Emptiness is the question the finalizer asks — a folder that exists
  but holds nothing is an agent that answered in chat instead of writing
  a file, which is not something to hand over as a download.
  """
  @spec artifact_files(String.t()) :: [String.t()]
  def artifact_files(folder_path) do
    folder_path
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, folder_path))
  end

  @doc """
  Zips a folder's contents in memory for download. Entries are relative
  to `folder_path`, so the archive unpacks into `<name>/` rather than
  reproducing the server's absolute layout.
  """
  @spec archive(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def archive(folder_path, name) do
    case artifact_files(folder_path) do
      [] ->
        {:error, :empty}

      files ->
        charlists = Enum.map(files, &String.to_charlist(Path.join(name, &1)))
        sources = Enum.map(files, &Path.join(folder_path, &1))

        case :zip.create(~c"#{name}.zip", Enum.zip(charlists, Enum.map(sources, &File.read!/1)), [
               :memory
             ]) do
          {:ok, {_filename, binary}} -> {:ok, binary}
          {:error, reason} -> {:error, reason}
        end
    end
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
