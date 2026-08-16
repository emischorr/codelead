defmodule CodeLead.Executor.DockerContainer do
  @moduledoc """
  Container executor (ADR-0003/0004): runs the agent inside a sibling
  Docker container created from the repository's declared `image_ref`
  through the host daemon. Worktree provisioning is delegated to
  `LocalSubprocess` — git stays host-side; the container only supplies
  the toolchain the agent's commands run against.

  Containers are cattle: durable state is the worktree and the per-task
  agent home on the workspace volume, and the container is recreated
  from the image whenever it is missing — `spawn/3` re-ensures it, so
  external removal costs nothing but a recreate. Identity is recovered
  from the deterministic name/labels, never from `exec_ref`.

  There is deliberately no default or fallback image: a repository that
  declares no environment cannot run in a container (`{:error,
  {:missing_execution_env, repo_name}}`), because a run in an
  environment nobody chose produces plausible-but-wrong results.
  """

  @behaviour CodeLead.Executor

  alias CodeLead.Executor.Context
  alias CodeLead.Executor.DockerCli
  alias CodeLead.Executor.HarnessStaging
  alias CodeLead.Executor.LocalSubprocess
  alias CodeLead.Executor.WorkspaceMount
  alias CodeLead.Projects
  alias CodeLead.Runtime.RunSupervisor
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace

  @impl CodeLead.Executor
  def provision(%Task{target: :repo, repository_id: repository_id} = task)
      when not is_nil(repository_id) do
    repository = Projects.get_repository!(repository_id)

    with {:ok, image_ref} <- declared_image(repository),
         {:ok, context} <- LocalSubprocess.provision(task),
         :ok <- ensure_agent_home(task.id),
         {:ok, name} <-
           ensure_container(
             task.id,
             task.project_id,
             image_ref,
             context.path,
             repository.preview_port
           ) do
      {:ok, %{context | exec_ref: name, executor: __MODULE__}}
    end
  end

  def provision(%Task{}), do: {:error, :container_target_unsupported}

  # Cheap checks only: the harness flavor depends on the task image's
  # libc, which is unknowable before a container exists — staging
  # happens in spawn/3 instead (ADR-0006).
  @impl CodeLead.Executor
  def available?([head | _args]) do
    with {:ok, _resolved} <- DockerCli.cli(),
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
         {:ok, name} <- ensure_container_for_spawn(context.task_id),
         {:ok, flavor} <- detect_libc(name),
         {:ok, binary} <- HarnessStaging.ensure_staged(flavor),
         {:ok, {cli_path, prefix}} <- DockerCli.cli() do
      exec_args =
        prefix ++
          ["exec", "-i", "-w", context.path] ++
          env_flags(context) ++ [name, binary | args]

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
    remove_container(task_id)

    if Keyword.get(opts, :keep, true) do
      :ok
    else
      _ = File.rm_rf(Workspace.agent_home(task_id))
      LocalSubprocess.teardown(context, keep: false)
    end
  end

  @doc """
  Refines a run-failure detail when the container itself is the story.
  Consulted by the fail path via `function_exported?/3`.
  """
  @spec diagnose(pos_integer()) :: {:ok, String.t()} | :none
  def diagnose(task_id) do
    case container_state(container_name(task_id)) do
      :absent -> {:ok, "task container was removed externally — retry recreates it"}
      {:stopped, _image, _bindings} -> {:ok, "task container exited unexpectedly"}
      _running_or_error -> :none
    end
  end

  @doc """
  The deterministic container name for a task — the identity every
  lifecycle command keys on, recoverable from the task id alone.
  """
  @spec container_name(pos_integer()) :: String.t()
  def container_name(task_id), do: "codelead-task-#{task_id}"

  @doc """
  Re-ensures the task's container from the task id alone — the entry
  point for execs that arrive outside a run (Developer terminal,
  preview), which must self-heal after external removal or a reaped
  Review-state container.
  """
  @spec ensure_for_task(pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def ensure_for_task(task_id), do: ensure_container_for_spawn(task_id)

  @doc """
  The `-e` exec flags for a command in the task's container: the given
  env plus the per-task base (HOME, git safe.directory) that must win
  over same-named project-env keys.
  """
  @spec exec_env_flags(pos_integer(), [{String.t(), String.t()}]) :: [String.t()]
  def exec_env_flags(task_id, env) do
    base = [
      {"HOME", Workspace.agent_home(task_id)},
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "safe.directory"},
      {"GIT_CONFIG_VALUE_0", "*"}
    ]

    Enum.flat_map(env ++ base, fn {key, value} -> ["-e", "#{key}=#{value}"] end)
  end

  defp declared_image(%{env_kind: :image, image_ref: ref}) when is_binary(ref) and ref != "" do
    {:ok, ref}
  end

  defp declared_image(repository), do: {:error, {:missing_execution_env, repository.name}}

  defp translate("claude-agent-acp") do
    case Application.get_env(:code_lead, :harness_version) do
      nil -> {:error, {:harness_not_staged, "HARNESS_VERSION is not configured"}}
      version -> {:ok, version}
    end
  end

  defp translate(other), do: {:error, {:container_command_unsupported, other}}

  # bun-compiled binaries are dynamically linked, so the staged harness
  # must match the task image's libc (ADR-0006). One ~50ms exec per
  # spawn; the image contract already requires `sh`.
  @libc_probe "if [ -e /lib/ld-musl-aarch64.so.1 ] || [ -e /lib/ld-musl-x86_64.so.1 ]; " <>
                "then echo musl; else echo glibc; fi"

  defp detect_libc(name) do
    case DockerCli.run(["exec", name, "sh", "-c", @libc_probe]) do
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
    File.mkdir_p(Workspace.agent_home(task_id))
  end

  # Reviewer contexts are hand-built and never pass through provision,
  # and a container can be removed externally at any time — so spawn
  # re-derives everything from the task id and re-ensures the container.
  defp ensure_container_for_spawn(task_id) do
    task = Tasks.get_task!(task_id)
    repository = Projects.get_repository!(task.repository_id)

    with {:ok, image_ref} <- declared_image(repository),
         :ok <- ensure_agent_home(task_id) do
      workdir = task.worktree_path || Workspace.worktree_path(task_id)
      ensure_container(task_id, task.project_id, image_ref, workdir, repository.preview_port)
    end
  end

  defp ensure_container(task_id, project_id, image_ref, workdir, preview_port) do
    name = container_name(task_id)

    recreate = fn ->
      create_container(name, task_id, project_id, image_ref, workdir, preview_port)
    end

    case container_state(name) do
      {:running, ^image_ref, bindings} ->
        if stale_preview_binding?(bindings, preview_port, task_id) do
          remove_container(task_id)
          recreate.()
        else
          {:ok, name}
        end

      {:stopped, ^image_ref, bindings} ->
        if stale_preview_binding?(bindings, preview_port, task_id) do
          remove_container(task_id)
          recreate.()
        else
          start_container(name)
        end

      :absent ->
        recreate.()

      {:error, reason} ->
        {:error, reason}

      {_state, _other_image, _bindings} ->
        # The repository's image_ref changed since the container was
        # created — cattle: recreate from the declared image.
        remove_container(task_id)
        recreate.()
    end
  end

  # A declared preview port with no published binding means the port was
  # declared (or changed) after the container was created. Recreating is
  # only safe with no live runner — killing the agent's exec to gain a
  # port binding is the wrong trade; until the next run, the preview's
  # error page explains itself.
  defp stale_preview_binding?(_bindings, nil, _task_id), do: false

  defp stale_preview_binding?(bindings, preview_port, task_id) do
    not Map.has_key?(bindings, "#{preview_port}/tcp") and
      task_id not in RunSupervisor.active_task_ids()
  end

  defp container_state(name) do
    format = "{{.State.Running}}|{{.Config.Image}}|{{json .HostConfig.PortBindings}}"

    case DockerCli.run(["container", "inspect", "--format", format, name]) do
      {:ok, output} ->
        case output |> String.trim() |> String.split("|", parts: 3) do
          ["true", image, bindings] -> {:running, image, parse_bindings(bindings)}
          [_not_running, image, bindings] -> {:stopped, image, parse_bindings(bindings)}
        end

      {:error, {:docker, _status, output}} ->
        if daemon_unreachable?(output) do
          {:error, {:docker_unreachable, trim_output(output)}}
        else
          :absent
        end

      {:error, :docker_cli_not_found} = error ->
        error
    end
  end

  defp parse_bindings(json) do
    case Jason.decode(json) do
      {:ok, %{} = bindings} -> bindings
      _null_or_invalid -> %{}
    end
  end

  defp create_container(name, task_id, project_id, image_ref, workdir, preview_port) do
    # 2147483647s (~68y) instead of `sleep infinity`, which BusyBox
    # does not support.
    args =
      ["create", "--name", name] ++
        [
          "--label",
          "codelead.managed=true",
          "--label",
          "codelead.task_id=#{task_id}",
          "--label",
          "codelead.project_id=#{project_id}"
        ] ++
        ["--entrypoint", "sleep", "-w", workdir] ++
        WorkspaceMount.flags() ++
        user_flags() ++
        cap_flags() ++
        publish_flags(preview_port) ++
        [image_ref, "2147483647"]

    with :ok <- ensure_image(image_ref),
         {:ok, _output} <- create(args) do
      start_container(name)
    end
  end

  # An ephemeral host port (`:0`) on a non-public interface: loopback in
  # dev, the docker bridge gateway in a deployed stack. Two tasks of the
  # same repo never collide, and nothing is exposed beyond the host —
  # browsers reach the preview only through the authenticated proxy,
  # which resolves the bound port via `docker port`.
  defp publish_flags(nil), do: []

  defp publish_flags(preview_port) do
    publish_ip = Application.get_env(:code_lead, :preview_publish_ip, "127.0.0.1")
    ["-p", "#{publish_ip}:0:#{preview_port}"]
  end

  defp ensure_image(image_ref) do
    case DockerCli.run(["image", "inspect", image_ref]) do
      {:ok, _output} ->
        :ok

      {:error, {:docker, _status, output}} ->
        # A socket problem must never be mistaken for a cache miss: pulling
        # would fail again and report itself as an image error.
        case classify(output, :absent) do
          :absent -> pull_image(image_ref)
          socket_failure -> {:error, socket_failure}
        end

      {:error, :docker_cli_not_found} = error ->
        error
    end
  end

  defp pull_image(image_ref) do
    case DockerCli.run(["pull", image_ref]) do
      {:ok, _output} ->
        :ok

      {:error, {:docker, _status, output}} ->
        {:error, classify(output, {:image_pull_failed, image_ref, trim_output(output)})}

      {:error, :docker_cli_not_found} = error ->
        error
    end
  end

  defp create(args) do
    case DockerCli.run(args) do
      {:ok, output} ->
        {:ok, output}

      {:error, {:docker, _status, output}} ->
        {:error, classify(output, {:container_create_failed, trim_output(output)})}

      {:error, :docker_cli_not_found} = error ->
        error
    end
  end

  defp start_container(name) do
    case DockerCli.run(["start", name]) do
      {:ok, _output} ->
        {:ok, name}

      {:error, {:docker, _status, output}} ->
        {:error, classify(output, {:container_start_failed, trim_output(output)})}

      {:error, :docker_cli_not_found} = error ->
        error
    end
  end

  defp remove_container(task_id) do
    _ = DockerCli.run(["rm", "-f", container_name(task_id)])
    :ok
  end

  defp user_flags do
    case Application.get_env(:code_lead, :container_user) do
      nil -> []
      user -> ["--user", user]
    end
  end

  defp cap_flags do
    cpus = Application.get_env(:code_lead, :container_cpus)
    memory_mb = Application.get_env(:code_lead, :container_memory_mb)

    Enum.concat(
      if(cpus, do: ["--cpus", cpus], else: []),
      if(memory_mb, do: ["--memory", "#{memory_mb}m"], else: [])
    )
  end

  # The merged env (project env + provider creds, assembled by the
  # driver) as exec flags — fresh every spawn, nothing baked into the
  # container's config.
  defp env_flags(%Context{task_id: task_id, env: env}), do: exec_env_flags(task_id, env)

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

  defp daemon_unreachable?(output) do
    Enum.any?(@unreachable_markers, &String.contains?(output, &1))
  end

  defp permission_denied?(output), do: String.contains?(output, @denied_marker)

  defp classify(output, fallback) do
    cond do
      permission_denied?(output) -> {:docker_permission_denied, trim_output(output)}
      daemon_unreachable?(output) -> {:docker_unreachable, trim_output(output)}
      true -> fallback
    end
  end

  defp trim_output(output) do
    output |> String.trim() |> String.slice(0, 500)
  end
end
