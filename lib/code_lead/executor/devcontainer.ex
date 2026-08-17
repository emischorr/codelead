defmodule CodeLead.Executor.Devcontainer do
  @moduledoc """
  Container executor (ADR-0009): provisions the task's execution
  environment from the repository's own `.devcontainer` configuration
  via the official devcontainer CLI (`devcontainer up`), then runs the
  agent, reviewers, terminal and preview through plain `docker exec`
  into the resolved primary container. Worktree provisioning is
  delegated to `LocalSubprocess` — git stays host-side.

  Environments are cattle: durable state is the worktree and the
  per-task agent home on the workspace, and identity is the
  `codelead.task_container`/`codelead.task_id` id-labels, recoverable
  from the task id alone — `devcontainer up` is idempotent, so
  re-running it heals a stopped or externally removed environment.
  There is no `devcontainer down`; teardown removes the environment by
  label, taking a compose project down as a whole when the primary
  container belongs to one.

  There is deliberately no fallback environment: a repository that does
  not declare devcontainer execution cannot run in a container
  (`{:error, {:missing_execution_env, repo_name}}`), and a declared one
  without a devcontainer config in the worktree fails visibly
  (`{:error, {:missing_devcontainer_config, repo_name}}`).
  """

  @behaviour CodeLead.Executor

  alias CodeLead.Executor.Context
  alias CodeLead.Executor.DevcontainerCli
  alias CodeLead.Executor.DockerCli
  alias CodeLead.Executor.HarnessStaging
  alias CodeLead.Executor.LocalSubprocess
  alias CodeLead.Executor.WorkspaceMount
  alias CodeLead.PreviewGateway.Relay
  alias CodeLead.Projects
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace

  @impl CodeLead.Executor
  def provision(%Task{target: :repo, repository_id: repository_id} = task)
      when not is_nil(repository_id) do
    repository = Projects.get_repository!(repository_id)

    with :ok <- declared_env(repository),
         {:ok, context} <- LocalSubprocess.provision(task),
         :ok <- ensure_agent_home(task.id),
         {:ok, container_id} <- up_environment(task, repository, context.path) do
      {:ok, %{context | exec_ref: container_id, executor: __MODULE__}}
    end
  end

  def provision(%Task{}), do: {:error, :container_target_unsupported}

  # Cheap checks only: the harness flavor depends on the environment's
  # libc, which is unknowable before a container exists — staging
  # happens in spawn/3 instead (ADR-0006).
  @impl CodeLead.Executor
  def available?([head | _args]) do
    with {:ok, _docker} <- DockerCli.cli(),
         {:ok, _devcontainer} <- DevcontainerCli.cli(),
         {:ok, _version} <- translate(head) do
      :ok
    end
  end

  # The first spawn per libc flavor may block minutes while the harness
  # is built (ADR-0005/0006); failures surface through the driver's
  # start_run error into the ordinary dispatch-failure path.
  @impl CodeLead.Executor
  def spawn(%Context{} = context, [head | args], port_opts \\ []) do
    with {:ok, _version} <- translate(head),
         {:ok, container_id} <- ensure_for_task(context.task_id),
         {:ok, flavor} <- detect_libc(container_id),
         {:ok, binary} <- HarnessStaging.ensure_staged(flavor),
         {:ok, {cli_path, prefix}} <- DockerCli.cli() do
      exec_args =
        prefix ++
          ["exec", "-i", "-w", context.path] ++
          exec_flags(context.task_id, container_id, context.env) ++
          [container_id, binary | args]

      # stderr stays unmerged for the same reason as LocalSubprocess:
      # JSON-RPC frames on stdout must not be corrupted.
      port =
        Port.open(
          {:spawn_executable, cli_path},
          [:binary, :exit_status, :hide, args: exec_args] ++ port_opts
        )

      {:ok, port}
    end
  end

  @impl CodeLead.Executor
  def teardown(%Context{task_id: task_id} = context, opts) do
    Relay.remove(task_id)
    remove_environment(task_id)

    if Keyword.get(opts, :keep, true) do
      :ok
    else
      _ = File.rm_rf(Workspace.agent_home(task_id))
      LocalSubprocess.teardown(context, keep: false)
    end
  end

  @doc """
  Refines a run-failure detail when the environment itself is the
  story. Consulted by the fail path via `function_exported?/3`.
  """
  @spec diagnose(pos_integer()) :: {:ok, String.t()} | :none
  def diagnose(task_id) do
    case container_for_task(task_id) do
      :absent -> {:ok, "task environment was removed externally — retry recreates it"}
      {:stopped, _id} -> {:ok, "task container exited unexpectedly"}
      _running_or_error -> :none
    end
  end

  @doc """
  The task's primary devcontainer, resolved by id-label — the identity
  every lifecycle command keys on, recoverable from the task id alone.
  """
  @spec container_for_task(pos_integer()) ::
          {:ok, String.t()} | {:stopped, String.t()} | :absent | {:error, term()}
  def container_for_task(task_id) do
    # --no-trunc: `ps` abbreviates ids to 12 chars while `devcontainer
    # up` reports the full id — keep the identity comparable.
    args =
      ["ps", "-a", "--no-trunc"] ++
        ["--filter", "label=codelead.task_container=true"] ++
        ["--filter", "label=codelead.task_id=#{task_id}"] ++
        ["--format", "{{.ID}}|{{.State}}"]

    case DockerCli.run(args) do
      {:ok, output} ->
        case output |> String.split("\n", trim: true) |> List.first() do
          nil -> :absent
          line -> parse_container_line(line)
        end

      {:error, {:docker, _status, output}} ->
        {:error, classify(output, {:docker_unreachable, trim_output(output)})}

      {:error, :docker_cli_not_found} = error ->
        error
    end
  end

  @doc """
  Re-ensures the task's environment from the task id alone — the entry
  point for execs that arrive outside a run (Developer terminal,
  preview), which must self-heal after external removal or a reaped
  Review-state environment. `devcontainer up` restarts a stopped
  environment and recreates a missing one.
  """
  @spec ensure_for_task(pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def ensure_for_task(task_id) do
    case container_for_task(task_id) do
      {:ok, container_id} -> {:ok, container_id}
      {:stopped, _id} -> reprovision(task_id)
      :absent -> reprovision(task_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The exec flags for a command in the task's environment: `--user` when
  the devcontainer config names a remote user (a plain `docker exec`
  would land on the container's default user instead), plus the given
  env and the per-task base (HOME, TMPDIR, git safe.directory) that
  must win over same-named project-env keys.
  """
  @spec exec_flags(pos_integer(), String.t(), [{String.t(), String.t()}]) :: [String.t()]
  def exec_flags(task_id, container_id, env) do
    base = [
      {"HOME", Workspace.agent_home(task_id)},
      # The environment's /tmp may not be writable for the exec user, so
      # every exec gets a tmp dir on the workspace it is known to own.
      {"TMPDIR", Path.join(Workspace.agent_home(task_id), ".tmp")},
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "safe.directory"},
      {"GIT_CONFIG_VALUE_0", "*"}
    ]

    user_flags(container_id) ++
      Enum.flat_map(env ++ base, fn {key, value} -> ["-e", "#{key}=#{value}"] end)
  end

  @doc """
  Removes the task's environment by label: a compose-based one goes
  down as a whole project (services included), a single container is
  force-removed; leftovers matching the task's id-labels are swept
  either way.
  """
  @spec remove_environment(pos_integer()) :: :ok
  def remove_environment(task_id) do
    case container_for_task(task_id) do
      {state, container_id} when state in [:ok, :stopped] ->
        case compose_project(container_id) do
          nil ->
            :noop

          project ->
            DockerCli.run(["compose", "-p", project, "down", "--volumes", "--remove-orphans"])
        end

        _ = DockerCli.run(["rm", "-f", container_id])
        :ok

      _absent_or_error ->
        :ok
    end
  end

  defp parse_container_line(line) do
    case String.split(line, "|", parts: 2) do
      [id, "running"] -> {:ok, id}
      [id, _other_state] -> {:stopped, id}
    end
  end

  defp declared_env(%{env_kind: :devcontainer}), do: :ok
  defp declared_env(repository), do: {:error, {:missing_execution_env, repository.name}}

  defp up_environment(%Task{} = task, repository, worktree) do
    with {:ok, config} <- resolve_config(worktree, repository) do
      id_labels = [
        {"codelead.managed", "true"},
        {"codelead.task_container", "true"},
        {"codelead.task_id", task.id},
        {"codelead.project_id", task.project_id}
      ]

      case DevcontainerCli.up(worktree,
             id_labels: id_labels,
             mounts: WorkspaceMount.devcontainer_mounts(),
             config: config
           ) do
        {:ok, %{container_id: container_id}} -> {:ok, container_id}
        {:error, _reason} = error -> error
      end
    end
  end

  # An explicit `devcontainer_path` must exist; without one the CLI's
  # own spec-order discovery decides, but the *presence* of a config is
  # verified here so a repo without one refuses with routing copy
  # instead of a raw CLI error.
  defp resolve_config(worktree, %{devcontainer_path: path} = repository)
       when is_binary(path) and path != "" do
    config = Path.join(worktree, path)

    if File.exists?(config) do
      {:ok, config}
    else
      {:error, {:missing_devcontainer_config, repository.name}}
    end
  end

  defp resolve_config(worktree, repository) do
    if discoverable_config?(worktree) do
      {:ok, nil}
    else
      {:error, {:missing_devcontainer_config, repository.name}}
    end
  end

  # The spec's discovery order: .devcontainer/devcontainer.json,
  # .devcontainer.json, .devcontainer/<folder>/devcontainer.json.
  defp discoverable_config?(worktree) do
    File.exists?(Path.join(worktree, ".devcontainer/devcontainer.json")) or
      File.exists?(Path.join(worktree, ".devcontainer.json")) or
      Path.wildcard(Path.join(worktree, ".devcontainer/*/devcontainer.json")) != []
  end

  defp reprovision(task_id) do
    task = Tasks.get_task!(task_id)
    repository = Projects.get_repository!(task.repository_id)

    with :ok <- declared_env(repository),
         :ok <- ensure_agent_home(task_id) do
      worktree = task.worktree_path || Workspace.worktree_path(task_id)
      up_environment(task, repository, worktree)
    end
  end

  defp translate("claude-agent-acp") do
    case Application.get_env(:code_lead, :harness_version) do
      nil -> {:error, {:harness_not_staged, "HARNESS_VERSION is not configured"}}
      version -> {:ok, version}
    end
  end

  defp translate(other), do: {:error, {:container_command_unsupported, other}}

  # bun-compiled binaries are dynamically linked, so the staged harness
  # must match the environment's libc (ADR-0006). One ~50ms exec per
  # spawn; any devcontainer image has `sh`.
  @libc_probe "if [ -e /lib/ld-musl-aarch64.so.1 ] || [ -e /lib/ld-musl-x86_64.so.1 ]; " <>
                "then echo musl; else echo glibc; fi"

  defp detect_libc(container_id) do
    case DockerCli.run(["exec", container_id, "sh", "-c", @libc_probe]) do
      {:ok, output} ->
        case String.trim(output) do
          "musl" -> {:ok, :musl}
          "glibc" -> {:ok, :glibc}
          other -> {:error, {:libc_probe_failed, trim_output(other)}}
        end

      {:error, {:docker, _status, output}} ->
        {:error, {:libc_probe_failed, trim_output(output)}}

      {:error, :docker_cli_not_found} = error ->
        error
    end
  end

  defp ensure_agent_home(task_id) do
    # `.tmp` backs the TMPDIR every exec receives; mkdir_p covers the
    # agent home itself.
    File.mkdir_p(Path.join(Workspace.agent_home(task_id), ".tmp"))
  end

  # `devcontainer up` records the merged configuration in the
  # `devcontainer.metadata` label but leaves the container's own user
  # untouched, so a plain exec would run as the image default (often
  # root) while the CLI's lifecycle hooks ran as `remoteUser`.
  defp user_flags(container_id) do
    case exec_user(container_id) do
      nil -> []
      user -> ["--user", user]
    end
  end

  defp exec_user(container_id) do
    format = "{{index .Config.Labels \"devcontainer.metadata\"}}"

    with {:ok, output} <- DockerCli.run(["inspect", "-f", format, container_id]),
         {:ok, layers} when is_list(layers) <- output |> String.trim() |> Jason.decode() do
      layers
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{"remoteUser" => user} when is_binary(user) and user != "" -> user
        %{"containerUser" => user} when is_binary(user) and user != "" -> user
        _no_user -> nil
      end)
    else
      _absent_or_invalid -> nil
    end
  end

  defp compose_project(container_id) do
    format = "{{index .Config.Labels \"com.docker.compose.project\"}}"

    case DockerCli.run(["inspect", "-f", format, container_id]) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          project -> project
        end

      {:error, _reason} ->
        nil
    end
  end

  # The CLI's wording for "no daemon at the other end" has changed across
  # versions and differs per transport, so match every form we have seen
  # rather than the one the current CLI happens to emit.
  @unreachable_markers [
    "Cannot connect to the Docker daemon",
    "error during connect",
    "failed to connect to the docker API",
    "Is the docker daemon running"
  ]

  @denied_marker "permission denied while trying to connect"

  defp classify(output, fallback) do
    cond do
      String.contains?(output, @denied_marker) ->
        {:docker_permission_denied, trim_output(output)}

      Enum.any?(@unreachable_markers, &String.contains?(output, &1)) ->
        {:docker_unreachable, trim_output(output)}

      true ->
        fallback
    end
  end

  defp trim_output(output) do
    output |> String.trim() |> String.slice(0, 500)
  end
end
