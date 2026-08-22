defmodule Mix.Tasks.CodeLead.Workspace.Clean do
  @shortdoc "Removes per-task worktrees and task folders from the workspace volume"

  @moduledoc """
  Drops the per-task state on the workspace volume: `worktrees/`,
  `tasks/`, `surveys/`, `merges/` and `agent-homes/`. Base clones under
  `repos/` are kept, so a reset does not
  re-clone every repository — they are only pruned of the worktree
  registrations that were just removed. Without the prune a later
  `git worktree add` on the same path fails as already registered.
  The staged harness under `harness/` is not per-task state and stays.

  Runs as part of `mix ecto.reset`, which reissues task ids while the
  workspace volume survives. A leftover `worktrees/task-<id>` would
  otherwise be picked up by the next task to be handed that id — even
  when it belongs to a different repository. Labeled task containers
  carry the same hazard, so they are removed too (best-effort, skipped
  when no docker CLI is around).

  Refuses to run while any task has a live or pending run (`queued`,
  `dispatched`, `executing` in the database) — cleaning would delete
  worktrees and containers out from under the running agents — and
  likewise while any task sits in Review, where a preview server or a
  Developer shell outlives the run and may still be writing into these
  paths. This task runs without the application started, so it cannot
  ask a live instance to stop those sessions; stopping the instance is
  what ends them. Pass `--force` to clean anyway; forcing also removes
  the live runs' containers.
  """

  use Mix.Task

  alias CodeLead.Executor.DockerCli
  alias CodeLead.Git
  alias CodeLead.Tasks
  alias CodeLead.Workspace
  alias CodeLead.Workspace.Remover

  @switches [force: :boolean]
  @live_states [:queued, :dispatched, :executing]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    Mix.Task.run("app.config")

    unless opts[:force], do: refuse_when_live!()

    root = Workspace.root()

    # Before any deletion: removing the labeled containers is the only
    # lever this VM has over processes still writing into the worktrees
    # (a preview server, a Developer shell). Sweeping afterwards races
    # them and produces the leftovers `Remover` then reports.
    sweep_containers()

    # Verified removal with the docker-root fallback: container runs
    # leave root-owned files a plain rm_rf cannot delete. A surviving
    # leftover warns instead of raising — a reset should not die halfway.
    Enum.each(
      ["worktrees", "tasks", "surveys", "merges", "agent-homes"],
      fn dir ->
        case Remover.remove_dir(Path.join(root, dir)) do
          :ok ->
            :ok

          {:error, reason} ->
            Mix.shell().error("could not fully remove #{dir}: #{inspect(reason)}")
        end
      end
    )

    Enum.each(base_clones(root), &Git.git(&1, ["worktree", "prune"]))

    Mix.shell().info("Cleaned per-task workspace state under #{root}")
  end

  # Two separate reasons, because the remedies differ: a live run is
  # stopped from the board, while a Review context is released by a
  # running instance this VM cannot talk to.
  defp refuse_when_live! do
    {run_ids, review_ids} = live_ids()

    refuse_when_live_runs!(run_ids)
    refuse_when_review_contexts!(review_ids)
  end

  defp refuse_when_live_runs!([]), do: :ok

  defp refuse_when_live_runs!(ids) do
    Mix.raise("""
    Refusing to clean: #{length(ids)} task(s) have a live or pending run \
    (ids: #{Enum.join(ids, ", ")}). Cleaning would delete their worktrees, \
    task folders, and containers out from under them.

    Stop the runs first, or pass --force to clean anyway.\
    """)
  end

  defp refuse_when_review_contexts!([]), do: :ok

  defp refuse_when_review_contexts!(ids) do
    Mix.raise("""
    Refusing to clean: #{length(ids)} task(s) are in Review \
    (ids: #{Enum.join(ids, ", ")}). Review is where an execution context \
    outlives its run — a preview server or a Developer shell may still be \
    writing into these paths, and this task runs without the application, \
    so it cannot ask the instance to stop them.

    Stop the instance first (which stops those processes), move the tasks \
    on, or pass --force to clean anyway.\
    """)
  end

  # The mix task runs in its own BEAM with the app not started, so it
  # cannot ask RunSupervisor — the database's run_state is the best
  # available signal. :failed is deliberately not blocking: a failed
  # run has no live process.
  defp live_ids do
    query = fn _repo -> {Tasks.active_runs(), Tasks.review_task_ids()} end

    case Ecto.Migrator.with_repo(CodeLead.Repo, query) do
      {:ok, {runs, review_ids}, _started_apps} ->
        run_ids = for %{id: id, run_state: run_state} <- runs, run_state in @live_states, do: id
        {run_ids, review_ids}

      {:error, reason} ->
        Mix.raise(
          "could not check for active runs (#{inspect(reason)}); pass --force to skip the check"
        )
    end
  rescue
    error in Postgrex.Error ->
      # A dropped or never-created database cannot have an instance
      # running against it.
      if error.postgres[:code] == :invalid_catalog_name do
        {[], []}
      else
        reraise(error, __STACKTRACE__)
      end

    _error in DBConnection.ConnectionError ->
      Mix.raise(
        "database unreachable — cannot check for active runs; pass --force to skip the check"
      )
  end

  defp sweep_containers do
    with true <- DockerCli.available?(),
         {:ok, output} <-
           DockerCli.run(["ps", "-aq", "--filter", "label=codelead.managed=true"]) do
      output
      |> String.split("\n", trim: true)
      |> Enum.each(&DockerCli.run(["rm", "-f", &1]))
    else
      _no_cli_or_no_daemon -> :ok
    end
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
