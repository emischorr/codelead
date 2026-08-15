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
  worktrees and containers out from under the running agents. Pass
  `--force` to clean anyway; forcing also removes the live runs'
  containers.
  """

  use Mix.Task

  alias CodeLead.Executor.DockerCli
  alias CodeLead.Git
  alias CodeLead.Tasks
  alias CodeLead.Workspace

  @switches [force: :boolean]
  @live_states [:queued, :dispatched, :executing]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    Mix.Task.run("app.config")

    unless opts[:force], do: refuse_when_live_runs!()

    root = Workspace.root()

    Enum.each(
      ["worktrees", "tasks", "surveys", "merges", "agent-homes"],
      &File.rm_rf!(Path.join(root, &1))
    )

    Enum.each(base_clones(root), &Git.git(&1, ["worktree", "prune"]))
    sweep_containers()

    Mix.shell().info("Cleaned per-task workspace state under #{root}")
  end

  defp refuse_when_live_runs! do
    case live_run_ids() do
      [] ->
        :ok

      ids ->
        Mix.raise("""
        Refusing to clean: #{length(ids)} task(s) have a live or pending run \
        (ids: #{Enum.join(ids, ", ")}). Cleaning would delete their worktrees, \
        task folders, and containers out from under them.

        Stop the runs first, or pass --force to clean anyway.\
        """)
    end
  end

  # The mix task runs in its own BEAM with the app not started, so it
  # cannot ask RunSupervisor — the database's run_state is the best
  # available signal. :failed is deliberately not blocking: a failed
  # run has no live process.
  defp live_run_ids do
    case Ecto.Migrator.with_repo(CodeLead.Repo, fn _repo -> Tasks.active_runs() end) do
      {:ok, runs, _started_apps} ->
        for %{id: id, run_state: run_state} <- runs, run_state in @live_states, do: id

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
        []
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
