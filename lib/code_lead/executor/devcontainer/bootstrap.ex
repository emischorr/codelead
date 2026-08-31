defmodule CodeLead.Executor.Devcontainer.Bootstrap do
  @moduledoc """
  One-shot boot work for the container executor: copies pre-staged
  harness runtimes from a `HARNESS_SOURCE` directory when one is
  configured (the lazy in-docker staging is
  `CodeLead.Executor.HarnessStaging`'s job, and boot never triggers it)
  and reaps orphaned task environments left by a crash. Runs as a
  supervised `Task`; every failure degrades to a log line, so an
  instance without docker — or without any container use — boots
  unaffected.
  """

  require Logger

  alias CodeLead.Executor.Devcontainer
  alias CodeLead.Executor.DockerCli
  alias CodeLead.Executor.HarnessStaging
  alias CodeLead.Runtime.LiveRuns
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task

  @spec run() :: :ok
  def run do
    stage_harness()
    reap_orphans()
    :ok
  rescue
    error ->
      Logger.warning("container bootstrap failed: #{Exception.message(error)}")
      :ok
  end

  # Boot only takes the cheap path — copying baked binaries per libc
  # flavor. Absent flavors are deferred to the first container run's
  # in-docker build rather than paying minutes on every fresh instance
  # whether or not containers are ever used (ADR-0005/0006).
  defp stage_harness do
    version = Application.get_env(:code_lead, :harness_version)
    source = Application.get_env(:code_lead, :harness_source)

    if is_nil(version) do
      Logger.info("harness staging skipped: HARNESS_VERSION unset")
    else
      Enum.each([:musl, :glibc], &stage_flavor(source, &1))
    end
  end

  defp stage_flavor(source, flavor) do
    baked = source && Path.join(source, Atom.to_string(flavor))

    if is_binary(baked) and File.dir?(baked) do
      _ = HarnessStaging.ensure_staged(flavor)
      :ok
    else
      Logger.info(
        "harness staging deferred (#{flavor}): no pre-staged runtime — " <>
          "staged in-docker on the first container run needing it"
      )
    end
  end

  # Compose service containers (a devcontainer's database, say) carry no
  # codelead labels, so the listing only surfaces primaries and relays —
  # a primary is reaped as a whole environment (compose project
  # included) while a relay is just a container.
  defp reap_orphans do
    if DockerCli.available?() do
      list_format = ~s({{.ID}} {{.Label "codelead.task_id"}} {{.Label "codelead.task_container"}})

      case DockerCli.run([
             "ps",
             "-a",
             "--filter",
             "label=codelead.managed=true",
             "--format",
             list_format
           ]) do
        {:ok, output} ->
          output
          |> String.split("\n", trim: true)
          |> Enum.each(&reap_line/1)

        {:error, _unreachable_or_failed} ->
          :ok
      end
    else
      Logger.debug("container reaper skipped: docker CLI not found")
    end
  end

  # executor_task_ids is re-checked per container rather than snapshotted:
  # a task dispatched while the reaper walks the list must not lose its
  # freshly ensured environment.
  defp reap_line(line) do
    with [id, task_id | rest] <- String.split(line, " "),
         {task_id_int, ""} <- Integer.parse(task_id),
         false <- keep_environment?(task_id_int) do
      if rest == ["true"] do
        _ = Devcontainer.remove_environment(task_id_int)
        Logger.info("reaped orphan task environment (task #{task_id_int})")
      else
        _ = DockerCli.run(["rm", "-f", id])
        Logger.info("reaped orphan managed container #{id} (task #{task_id_int})")
      end
    else
      _kept_or_unparsable -> :ok
    end
  end

  # A task in Review has no runner but is still being judged — its
  # environment hosts reviewer execs, the Developer terminal, and the
  # live preview, so a restart must not take it down (execs self-heal
  # the environment, but a dev server running inside it would not come
  # back).
  defp keep_environment?(task_id) do
    task_id in LiveRuns.executor_task_ids() or review_environment?(task_id)
  end

  defp review_environment?(task_id) do
    match?(
      %Task{state: :review, execution_env: :container},
      Tasks.get_task(task_id)
    )
  end
end
