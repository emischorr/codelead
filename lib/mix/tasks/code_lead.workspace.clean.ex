defmodule Mix.Tasks.CodeLead.Workspace.Clean do
  @shortdoc "Removes per-task worktrees and task folders from the workspace volume"

  @moduledoc """
  Drops the per-task state on the workspace volume: `worktrees/`,
  `tasks/`, `surveys/` and `merges/`. Base clones under `repos/` are kept, so a reset does not
  re-clone every repository — they are only pruned of the worktree
  registrations that were just removed. Without the prune a later
  `git worktree add` on the same path fails as already registered.

  Runs as part of `mix ecto.reset`, which reissues task ids while the
  workspace volume survives. A leftover `worktrees/task-<id>` would
  otherwise be picked up by the next task to be handed that id — even
  when it belongs to a different repository.
  """

  use Mix.Task

  alias CodeLead.Git
  alias CodeLead.Workspace

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    root = Workspace.root()

    Enum.each(["worktrees", "tasks", "surveys", "merges"], &File.rm_rf!(Path.join(root, &1)))
    Enum.each(base_clones(root), &Git.git(&1, ["worktree", "prune"]))

    Mix.shell().info("Cleaned per-task workspace state under #{root}")
  end

  defp base_clones(root) do
    case File.ls(Path.join(root, "repos")) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join([root, "repos", &1]))
        |> Enum.filter(&File.dir?/1)

      {:error, _reason} ->
        []
    end
  end
end
