defmodule CodeLead.Workspace.Reconciler do
  @moduledoc """
  One-shot boot step that heals persisted workspace paths after a
  `WORKSPACE_ROOT` move.

  Absolute paths live in three places: `repositories.base_clone_path`,
  `tasks.worktree_path`, and git's own worktree gitdir cross-pointers.
  A root move (a deployment switching volumes, say) strands all three
  — worst case, a stale DB path makes the next run re-clone into a
  container's ephemeral layer, and everything committed there dies with
  the container. This step runs before anything can dispatch:

  1. DB rows pointing outside the current root are rewritten to the
     recomputed location — only when the files actually exist there;
     genuinely lost paths are logged and left in place (the guarded
     resolvers never trust them, so they are inert).
  2. `git worktree repair` re-links every surviving worktree to its
     base clone, healing pointers the DB cannot see.

  Nothing is ever deleted. The step blocks the supervisor (children
  after it wait), degrades every failure to a log line, and is skipped
  under `:reconcile_workspace_at_boot, false` — the test env, where
  boot-time Repo queries would race the Ecto sandbox.
  """

  import Ecto.Query

  require Logger

  alias CodeLead.Git
  alias CodeLead.Projects.Repository
  alias CodeLead.Repo
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :temporary}
  end

  @doc """
  Runs the reconciliation synchronously and yields the supervisor slot —
  `:ignore` keeps no process around, the ordering is the point.
  """
  @spec start_link() :: :ignore
  def start_link do
    if Application.get_env(:code_lead, :reconcile_workspace_at_boot, true), do: run()

    :ignore
  end

  @spec run() :: :ok
  def run do
    repositories = reconcile_repositories()
    tasks = reconcile_tasks()
    repaired = repair_worktrees()

    if repositories + tasks + repaired > 0 do
      Logger.info(
        "workspace reconciliation: #{repositories} repository path(s) and " <>
          "#{tasks} worktree path(s) rewritten, #{repaired} base clone(s) repaired"
      )
    end

    :ok
  rescue
    error ->
      Logger.error("workspace reconciliation failed: #{Exception.message(error)}")
      :ok
  end

  defp reconcile_repositories do
    Repo.all(from r in Repository, where: not is_nil(r.base_clone_path))
    |> Enum.reject(&Workspace.under_root?(&1.base_clone_path))
    |> Enum.count(&heal_repository/1)
  end

  defp heal_repository(repository) do
    recomputed = Workspace.base_clone_path(repository.name, repository.id)

    if File.dir?(Path.join(recomputed, ".git")) do
      {:ok, _} =
        repository
        |> Ecto.Changeset.change(base_clone_path: recomputed)
        |> Repo.update()

      Logger.info(
        "repository #{repository.id}: base clone moved with the workspace root — " <>
          "#{repository.base_clone_path} → #{recomputed}"
      )

      true
    else
      Logger.error(
        "repository #{repository.id}: base clone recorded at " <>
          "#{repository.base_clone_path} — outside the workspace root and not found at " <>
          "#{recomputed}; the next run re-clones fresh, and commits that existed only " <>
          "there are lost"
      )

      false
    end
  end

  defp reconcile_tasks do
    Repo.all(from t in Task, where: not is_nil(t.worktree_path))
    |> Enum.reject(&Workspace.under_root?(&1.worktree_path))
    |> Enum.count(&heal_task/1)
  end

  defp heal_task(task) do
    recomputed = Workspace.worktree_path(task.id)

    if File.dir?(recomputed) do
      {:ok, _} =
        task
        |> Ecto.Changeset.change(worktree_path: recomputed)
        |> Repo.update()

      Logger.info(
        "task #{task.id}: worktree moved with the workspace root — " <>
          "#{task.worktree_path} → #{recomputed}"
      )

      true
    else
      Logger.error(
        "task #{task.id}: worktree recorded at #{task.worktree_path} — outside the " <>
          "workspace root and not found at #{recomputed}; lost"
      )

      false
    end
  end

  # Runs every boot: a root move leaves the *gitdir files* stale even
  # when the DB rows are already current, and repairing an intact link
  # is a no-op. Base clone paths come fresh from the DB — the passes
  # above may just have rewritten them.
  defp repair_worktrees do
    worktrees_by_repository =
      Repo.all(
        from t in Task,
          where: not is_nil(t.worktree_path) and not is_nil(t.repository_id),
          select: {t.repository_id, t.worktree_path}
      )
      |> Enum.filter(fn {_repository_id, path} -> File.dir?(path) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Repo.all(from r in Repository, where: not is_nil(r.base_clone_path))
    |> Enum.filter(&File.dir?(Path.join(&1.base_clone_path, ".git")))
    |> Enum.count(&repair_repository(&1, worktrees_by_repository[&1.id] || []))
  end

  defp repair_repository(_repository, []), do: false

  defp repair_repository(repository, worktree_paths) do
    case Git.repair_worktrees(repository.base_clone_path, worktree_paths) do
      {:ok, ""} ->
        false

      {:ok, output} ->
        Logger.info("repository #{repository.id}: worktree links repaired — #{output}")
        true

      {:error, output} ->
        # Partial repairs still count as work done; unhealable links
        # (a pruned admin gitdir) recover at the next dispatch via the
        # surviving branch.
        Logger.warning("repository #{repository.id}: worktree repair reported — #{output}")
        true
    end
  end
end
