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
         {:ok, name} <- ensure_container(task.id, task.project_id, image_ref, context.path) do
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
      {:stopped, _image} -> {:ok, "task container exited unexpectedly"}
      _running_or_error -> :none
    end
  end

  @doc """
  The deterministic container name for a task — the identity every
  lifecycle command keys on, recoverable from the task id alone.
  """
  @spec container_name(pos_integer()) :: String.t()
  def container_name(task_id), do: "codelead-task-#{task_id}"

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
      ensure_container(task_id, task.project_id, image_ref, workdir)
    end
  end

  defp ensure_container(task_id, project_id, image_ref, workdir) do
    name = container_name(task_id)

    case container_state(name) do
      {:running, ^image_ref} ->
        {:ok, name}

      {:stopped, ^image_ref} ->
        start_container(name)

      :absent ->
        create_container(name, task_id, project_id, image_ref, workdir)

      {:error, reason} ->
        {:error, reason}

      {_state, _other_image} ->
        # The repository's image_ref changed since the container was
        # created — cattle: recreate from the declared image.
        remove_container(task_id)
        create_container(name, task_id, project_id, image_ref, workdir)
    end
  end

  defp container_state(name) do
    format = "{{.State.Running}}|{{.Config.Image}}"

    case DockerCli.run(["container", "inspect", "--format", format, name]) do
      {:ok, output} ->
        case output |> String.trim() |> String.split("|", parts: 2) do
          ["true", image] -> {:running, image}
          [_not_running, image] -> {:stopped, image}
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

  defp create_container(name, task_id, project_id, image_ref, workdir) do
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
        [image_ref, "2147483647"]

    with :ok <- ensure_image(image_ref),
         {:ok, _output} <- create(args) do
      start_container(name)
    end
  end

  defp ensure_image(image_ref) do
    case DockerCli.run(["image", "inspect", image_ref]) do
      {:ok, _output} ->
        :ok

      {:error, {:docker, _status, output}} ->
        if daemon_unreachable?(output) do
          {:error, {:docker_unreachable, trim_output(output)}}
        else
          pull_image(image_ref)
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
  # container's config. HOME and the git safe.directory override come
  # last so they win over any project-env key of the same name.
  defp env_flags(%Context{task_id: task_id, env: env}) do
    base = [
      {"HOME", Workspace.agent_home(task_id)},
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "safe.directory"},
      {"GIT_CONFIG_VALUE_0", "*"}
    ]

    Enum.flat_map(env ++ base, fn {key, value} -> ["-e", "#{key}=#{value}"] end)
  end

  defp daemon_unreachable?(output) do
    output =~ "Cannot connect to the Docker daemon" or output =~ "error during connect"
  end

  defp classify(output, fallback) do
    if daemon_unreachable?(output), do: {:docker_unreachable, trim_output(output)}, else: fallback
  end

  defp trim_output(output) do
    output |> String.trim() |> String.slice(0, 500)
  end
end
