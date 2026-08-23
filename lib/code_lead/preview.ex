defmodule CodeLead.Preview do
  @moduledoc """
  One-click preview servers — the automation behind the Review tab's
  Start/Stop button. One `Session` per task owns the dev-server process
  started from the repository's `preview_command` and probes the
  preview upstream until it answers a request; state changes
  (`:starting → :ready`, `:unreachable`, `{:failed, log_tail}`,
  `:stopped`) broadcast on the task's own topic as
  `{:preview_state, task_id, status}`.

  The session mirrors `CodeLead.Terminal`: local tasks run the command
  as a host shell in the worktree, container tasks through
  `docker exec` into the task's devcontainer (licensed like every
  container exec). The manual flow — starting the server from the
  Terminal tab — keeps working; a session is a convenience on top, and
  the proxy never depends on one.
  """

  require Logger

  alias CodeLead.Executor.Devcontainer
  alias CodeLead.Executor.DockerCli
  alias CodeLead.Executor.EnvScrub
  alias CodeLead.License
  alias CodeLead.OsProcess
  alias CodeLead.Preview.Session
  alias CodeLead.PreviewGateway
  alias CodeLead.Projects
  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace

  @registry CodeLead.Preview.Registry
  @supervisor CodeLead.Preview.SessionSupervisor
  @default_idle_ms 30 * 60_000
  @default_start_timeout_ms 120_000
  @default_liveness_ms 10_000
  @probe_connect_ms 1_000
  @probe_response_ms 2_000

  @typedoc """
  `:unreachable` is a server that answered once and stopped — distinct
  from `{:failed, _}`, which never served at all, and from `:stopped`,
  which is a session that no longer exists.
  """
  @type status :: :stopped | :starting | :ready | :unreachable | {:failed, String.t()}

  @doc """
  The task's live preview session, starting one if needed. `opts`:
  `:extra_env` (pre-computed pairs such as PREVIEW_BASE_PATH — the
  caller owns any cross-domain lookups).

  A session whose fingerprint no longer matches the active gateway is
  stopped and replaced rather than reused: its server captured the old
  `PREVIEW_BASE_PATH` at spawn and would keep serving it forever.
  """
  @spec ensure_session(Task.t(), keyword()) ::
          {:ok, pid()}
          | {:error,
             :no_preview_command
             | :no_preview_port
             | :no_worktree
             | :port_in_use
             | :container_unlicensed
             | term()}
  def ensure_session(%Task{} = task, opts \\ []) do
    case whereis(task.id) do
      pid when is_pid(pid) -> reuse_or_restart(task, pid, opts)
      nil -> start_session(task, opts)
    end
  end

  @doc """
  Stops the task's preview server, if one runs. Safe at any time —
  teardown and stage transitions call it unconditionally.
  """
  @spec stop(pos_integer()) :: :ok
  def stop(task_id) do
    case whereis(task_id) do
      nil -> :ok
      pid -> GenServer.call(pid, :stop, 30_000)
    end
  catch
    # The session can exit between lookup and call.
    :exit, _reason -> :ok
  end

  @doc """
  The session's current lifecycle state; `:stopped` when none runs.
  A failure is terminal for the session, so its detail travels in the
  `{:preview_state, task_id, {:failed, log_tail}}` broadcast rather
  than being queryable here.
  """
  @spec status(pos_integer()) :: status()
  def status(task_id) do
    case whereis(task_id) do
      nil -> :stopped
      pid -> GenServer.call(pid, :status, 5_000)
    end
  catch
    :exit, _reason -> :stopped
  end

  @doc """
  Task ids with a live preview session, adopted ones included. This is
  the truth about *processes*, node-local like the registry itself — a
  session counts from the moment it starts, whether or not its server
  answers on the preview port yet.
  """
  @spec active_task_ids() :: [pos_integer()]
  def active_task_ids do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Subscribes to the org-wide preview topic, which carries every
  session's open and close as `{:preview_session, :opened | :closed,
  task_id}`.

  A subscriber tracks the live set from these messages. It must **not**
  re-read the registry when a close arrives: the session broadcasts from
  `terminate/2`, while it is still registered, so a recount there reads
  one too many and stays wrong until the next reconcile.
  """
  @spec subscribe_org() :: :ok | {:error, term()}
  def subscribe_org do
    Phoenix.PubSub.subscribe(CodeLead.PubSub, org_topic())
  end

  @doc """
  Attaches the calling process as a viewer (monitored; a crashed viewer
  detaches implicitly) — a session with no viewers stops after the idle
  timeout.
  """
  @spec attach(pos_integer()) :: :ok
  def attach(task_id) do
    case whereis(task_id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:attach, self()}, 5_000)
    end
  catch
    :exit, _reason -> :ok
  end

  @spec detach(pos_integer()) :: :ok
  def detach(task_id) do
    case whereis(task_id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:detach, self()}, 5_000)
    end
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Boot entry point for `adopt_survivors/0`, skipped under
  `:adopt_previews_at_boot, false` — the test env, where a boot-time
  Repo query would race the Ecto sandbox.
  """
  @spec adopt_at_boot() :: :ok
  def adopt_at_boot do
    if Application.get_env(:code_lead, :adopt_previews_at_boot, true),
      do: adopt_survivors(),
      else: :ok
  end

  @doc """
  Re-attaches sessions to container previews that outlived the VM.
  Best-effort: a task in Review whose recorded pid still runs in its
  container gets a session back — status chip, Stop button and idle
  timeout included — instead of a second server on the next start.
  """
  @spec adopt_survivors() :: :ok
  def adopt_survivors do
    cond do
      not DockerCli.available?() ->
        :ok

      not License.feature_enabled?(:container_execution_env) ->
        # Community instances run no container execs at all; a survivor
        # here is the reaper's business, not ours.
        :ok

      true ->
        Enum.each(Tasks.review_task_ids(), &adopt_survivor/1)
    end
  rescue
    error ->
      Logger.warning("preview adoption failed: #{Exception.message(error)}")
      :ok
  end

  @doc false
  @spec broadcast(pos_integer(), status()) :: :ok
  def broadcast(task_id, status) do
    Phoenix.PubSub.broadcast(
      CodeLead.PubSub,
      Tasks.task_topic(task_id),
      {:preview_state, task_id, status}
    )
  end

  @doc false
  @spec broadcast_session(pos_integer(), :opened | :closed) :: :ok
  def broadcast_session(task_id, lifecycle) do
    Phoenix.PubSub.broadcast(
      CodeLead.PubSub,
      org_topic(),
      {:preview_session, lifecycle, task_id}
    )
  end

  @doc false
  @spec via(pos_integer()) :: {:via, Registry, {module(), pos_integer()}}
  def via(task_id), do: {:via, Registry, {@registry, task_id}}

  @doc false
  @spec idle_ms() :: pos_integer()
  def idle_ms, do: Application.get_env(:code_lead, :preview_idle_ms, @default_idle_ms)

  @doc false
  @spec start_timeout_ms() :: pos_integer()
  def start_timeout_ms do
    Application.get_env(:code_lead, :preview_start_timeout_ms, @default_start_timeout_ms)
  end

  @doc """
  How often a server that has already answered is re-checked. Not an
  operator knob — a tenth of the startup pace is right everywhere; it
  reads app env so tests need not wait it out.
  """
  @spec liveness_ms() :: pos_integer()
  def liveness_ms do
    Application.get_env(:code_lead, :preview_liveness_ms, @default_liveness_ms)
  end

  @spec child_specs() :: [Supervisor.child_spec() | {module(), term()}]
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]
  end

  defp org_topic, do: "org:previews"

  # Registry unregistration is asynchronous after a session dies, so a
  # lookup can briefly return a dead pid — treat it as gone.
  defp whereis(task_id) do
    case Registry.lookup(@registry, task_id) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid, else: nil
      [] -> nil
    end
  end

  defp reuse_or_restart(%Task{} = task, pid, opts) do
    if matches?(pid, fingerprint(task, opts)) do
      {:ok, pid}
    else
      Logger.info(
        "preview server for task #{task.id} predates the active gateway — restarting it"
      )

      stop_and_await(task.id, pid)
      start_session(task, opts)
    end
  end

  defp start_session(%Task{target: :repo, repository_id: repository_id} = task, opts)
       when not is_nil(repository_id) do
    repository = Projects.get_repository!(repository_id)

    cond do
      is_nil(repository.preview_command) -> {:error, :no_preview_command}
      # Without one `preview_env/2` returns nothing at all, so the
      # command's `$PREVIEW_PORT` expands to empty and the only symptom
      # is a probe that never readies. Refuse where the cause is legible.
      is_nil(repository.preview_port) -> {:error, :no_preview_port}
      is_nil(task.worktree_path) -> {:error, :no_worktree}
      true -> start_session(task, repository.preview_command, opts)
    end
  end

  defp start_session(%Task{}, _opts), do: {:error, :no_preview_command}

  # No session owns this task, so anything already answering is a server
  # CodeLead does not manage — hand-started from the Terminal, or one
  # that outlived its session. Spawning a second one produces a process
  # that dies on the bound port while this very probe reports `:ready`
  # from the *old* one, which is how a stale base path survives a
  # gateway switch unnoticed.
  defp start_session(task, preview_command, opts) do
    if probe(task).() == :ready do
      {:error, :port_in_use}
    else
      spawn_session(task, preview_command, opts)
    end
  end

  defp spawn_session(task, preview_command, opts) do
    with {:ok, spec} <- spawn_spec(task, preview_command, session_env(task, opts)) do
      record_url(task.id, gateway_url(task))
      spec = Map.put(spec, :fingerprint, fingerprint(task, opts))

      case DynamicSupervisor.start_child(@supervisor, {Session, spec}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        error -> error
      end
    end
  end

  # Never `ensure_for_task/1`: adoption re-attaches to an environment
  # that is already up, and must not bring one back to life.
  defp adopt_survivor(task_id) do
    with %Task{execution_env: :container} = task <- Tasks.get_task(task_id),
         nil <- whereis(task_id),
         {:ok, pid} <- recorded_pid(task_id),
         {:ok, container_id} <- Devcontainer.container_for_task(task_id),
         :ok <- alive_in_container(container_id, pid) do
      url = gateway_url(task)

      if recorded_url(task_id) == url do
        adopt(task, container_id, pid, url)
      else
        discard_survivor(task_id, container_id, pid)
      end
    else
      _nothing_to_adopt -> :ok
    end
  end

  defp adopt(%Task{id: task_id} = task, container_id, pid, url) do
    spec = %{
      task_id: task_id,
      port_opener: nil,
      stopper: container_stopper(container_id, pid_file(task_id)),
      probe: probe(task),
      # The env this server was spawned with died with the VM that
      # spawned it, so only the URL half is knowable here.
      fingerprint: %{url: url, env: nil}
    }

    case DynamicSupervisor.start_child(@supervisor, {Session, spec}) do
      {:ok, _pid} ->
        Logger.info("adopted surviving preview server (task #{task_id}, pid #{pid})")

      _already_started_or_failed ->
        :ok
    end
  end

  # A survivor from another gateway serves the base path it captured at
  # spawn, and no probe can tell — it answers perfectly, just with the
  # wrong asset URLs. Signalling it here is what makes switching
  # PREVIEW_DOMAIN work for tasks already sitting in Review.
  defp discard_survivor(task_id, container_id, pid) do
    Logger.info(
      "preview server for task #{task_id} (pid #{pid}) predates the active gateway — stopping it"
    )

    container_stopper(container_id, pid_file(task_id)).(nil)
    :ok
  end

  # What a running server would have to have been started for to still
  # be correct: the browser-facing URL (which is what the gateway
  # decides) and the injected env. `nil` on either side means "unknown"
  # — an adopted session knows only the URL — and unknown never forces
  # a restart on its own.
  defp fingerprint(%Task{} = task, opts) do
    %{url: gateway_url(task), env: Keyword.get(opts, :extra_env, [])}
  end

  defp matches?(pid, %{url: url, env: env}) do
    case GenServer.call(pid, :fingerprint, 5_000) do
      %{url: nil} -> true
      %{url: ^url, env: nil} -> true
      %{url: ^url, env: ^env} -> true
      _drifted -> false
    end
  catch
    # A session dying under us is not a mismatch; the restart it would
    # trigger is the same thing the next lookup does anyway.
    :exit, _gone -> true
  end

  # Reads application env only — no `Endpoint` — because boot adoption
  # runs before `CodeLeadWeb.Endpoint` starts. That also means a bare
  # PHX_HOST change (which moves PREVIEW_ORIGIN but not the relative
  # path-gateway URL) is caught only by the `:env` half.
  defp gateway_url(%Task{} = task) do
    case PreviewGateway.impl().url_for(task) do
      {:ok, url} -> url
      {:error, _no_url} -> nil
    end
  end

  # `stop/1` returns as soon as the session replies, but the session is
  # still in `terminate/2` — a container stopper waits up to 5s on a
  # `docker exec` — and stays registered until it exits, so restarting
  # in the same call would collide with the corpse's name.
  defp stop_and_await(task_id, pid) do
    ref = Process.monitor(pid)
    stop(task_id)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      30_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end

    await_deregistered(task_id)
  end

  # The registry drops the key from its own DOWN handler, which races
  # ours.
  defp await_deregistered(task_id, attempts \\ 100) do
    case Registry.lookup(@registry, task_id) do
      [] ->
        :ok

      _still_taken when attempts > 0 ->
        Process.sleep(10)
        await_deregistered(task_id, attempts - 1)

      _still_taken ->
        :ok
    end
  end

  # Written beside the pid file and, like it, never deleted on stop: it
  # is stale by construction, and only a live process makes it mean
  # anything.
  defp record_url(_task_id, nil), do: :ok

  defp record_url(task_id, url) do
    file = url_file(task_id)
    _ = File.mkdir_p(Path.dirname(file))
    _ = File.write(file, url)
    :ok
  end

  defp recorded_url(task_id) do
    case File.read(url_file(task_id)) do
      {:ok, contents} -> String.trim(contents)
      {:error, _no_url_file} -> nil
    end
  end

  defp url_file(task_id) do
    Path.join(Workspace.agent_home(task_id), "preview.url")
  end

  # The pid file is never deleted on stop, so it is stale by
  # construction — liveness is what makes it meaningful, never the file.
  defp recorded_pid(task_id) do
    case File.read(pid_file(task_id)) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> :error
          pid -> {:ok, pid}
        end

      {:error, _no_pid_file} ->
        :error
    end
  end

  defp alive_in_container(container_id, pid) do
    case DockerCli.run(["exec", container_id, "sh", "-c", "kill -0 #{pid}"], timeout: 5_000) do
      {:ok, _alive} -> :ok
      {:error, _gone_or_unreachable} -> :error
    end
  end

  defp session_env(task, opts) do
    Projects.env_vars(task.project_id) ++ Keyword.get(opts, :extra_env, [])
  end

  defp spawn_spec(%Task{execution_env: :container} = task, preview_command, env) do
    with :ok <- check_container_license(),
         {:ok, container_id} <- Devcontainer.ensure_for_task(task.id),
         {:ok, {cli_path, prefix}} <- DockerCli.cli() do
      pid_file = pid_file(task.id)
      _ = File.mkdir_p(Path.dirname(pid_file))
      exec_flags = Devcontainer.exec_flags(task.id, container_id, env)

      args =
        prefix ++
          ["exec", "-i", "-w", task.worktree_path] ++
          exec_flags ++
          [
            container_id,
            "sh",
            "-lc",
            OsProcess.record_pid_and_exec(preview_command, pid_file)
          ]

      {:ok,
       %{
         task_id: task.id,
         port_opener: fn -> open_port(cli_path, args, []) end,
         stopper: container_stopper(container_id, pid_file),
         probe: probe(task)
       }}
    end
  end

  defp spawn_spec(%Task{} = task, preview_command, env) do
    port_env = EnvScrub.port_env(env)

    case System.find_executable(shell()) do
      nil ->
        {:error, {:shell_not_found, shell()}}

      shell_path ->
        args = ["-lc", preview_command]

        {:ok,
         %{
           task_id: task.id,
           port_opener: fn ->
             open_port(shell_path, args, cd: task.worktree_path, env: port_env)
           end,
           # `sh -lc` is its own process-group leader and everything the
           # command starts inherits that group, so the group — not the
           # shell's pid — is what has to be signalled. Closing the port
           # kills nothing (ADR-0013).
           stopper: fn
             nil -> :ok
             os_pid -> OsProcess.terminate_group(os_pid)
           end,
           probe: probe(task)
         }}
    end
  end

  # Shared by the spawning and the adopting path so the two cannot
  # drift. Closes over strings only: a stopper runs under a supervisor
  # shutdown, where the Repo may already be on its way down.
  defp container_stopper(container_id, pid_file) do
    fn _os_pid ->
      _ =
        DockerCli.run(
          ["exec", container_id, "sh", "-c", OsProcess.terminate_group_script(pid_file)],
          timeout: 5_000
        )

      :ok
    end
  end

  defp pid_file(task_id) do
    Path.join(Workspace.agent_home(task_id), "preview.pid")
  end

  # Readiness = the preview upstream accepts a TCP connection, resolved
  # through the same gateway the proxy uses (for container tasks this
  # also ensures the relay).
  # An open port is not evidence. A container upstream is reached
  # through the relay sidecar's published port, and both docker's
  # publish path and socat's listener accept before anything touches the
  # dev server — so a server that never bound leaves the connect
  # succeeding and every request failing, which is the exact shape this
  # probe exists to catch. The connect stays as the cheap gate that
  # fails fast while a server is still booting; the answer comes from a
  # request.
  defp probe(task) do
    fn ->
      case PreviewGateway.impl().upstream_for(task) do
        {:ok, %{host: host, port: port}} -> probe_upstream(host, port)
        {:error, _unresolvable} -> :waiting
      end
    end
  end

  defp probe_upstream(host, port) do
    if connectable?(host, port), do: answers?(host, port), else: :waiting
  end

  defp connectable?(host, port) do
    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, active: false],
           @probe_connect_ms
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _refused} ->
        false
    end
  end

  # Any status answers the only question asked — is a server there? A
  # 404 or a 500 from an app still wiring itself up counts. Only a
  # transport failure means not yet, and `:closed` is the telling one:
  # that is a relay accepting on behalf of a dev server that is not
  # listening.
  defp answers?(host, port) do
    request =
      Req.new(
        method: :get,
        url: "http://#{host}:#{port}/",
        redirect: false,
        retry: false,
        raw: true,
        receive_timeout: @probe_response_ms,
        connect_options: [timeout: @probe_connect_ms]
      )

    case Req.request(request) do
      {:ok, _answered} -> :ready
      {:error, _transport} -> :waiting
    end
  end

  defp open_port(exe, args, extra_opts) do
    opts =
      [:binary, :exit_status, :hide, :stderr_to_stdout, args: args] ++
        Enum.reject(extra_opts, fn
          {:cd, nil} -> true
          _keep -> false
        end)

    Port.open({:spawn_executable, exe}, opts)
  end

  defp check_container_license do
    if License.feature_enabled?(:container_execution_env) do
      :ok
    else
      {:error, :container_unlicensed}
    end
  end

  defp shell, do: Application.get_env(:code_lead, :terminal_shell, "sh")
end
