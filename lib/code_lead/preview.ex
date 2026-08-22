defmodule CodeLead.Preview do
  @moduledoc """
  One-click preview servers — the automation behind the Review tab's
  Start/Stop button. One `Session` per task owns the dev-server process
  started from the repository's `preview_command` and probes the
  preview upstream until the port answers; state changes
  (`:starting → :ready`, `{:failed, log_tail}`, `:stopped`) broadcast
  on the task's own topic as `{:preview_state, task_id, status}`.

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

  @type status :: :stopped | :starting | :ready | {:failed, String.t()}

  @doc """
  The task's live preview session, starting one if needed. `opts`:
  `:extra_env` (pre-computed pairs such as PREVIEW_BASE_PATH — the
  caller owns any cross-domain lookups).
  """
  @spec ensure_session(Task.t(), keyword()) ::
          {:ok, pid()}
          | {:error, :no_preview_command | :no_worktree | :container_unlicensed | term()}
  def ensure_session(%Task{} = task, opts \\ []) do
    case whereis(task.id) do
      pid when is_pid(pid) -> {:ok, pid}
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

  @spec child_specs() :: [Supervisor.child_spec() | {module(), term()}]
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]
  end

  # Registry unregistration is asynchronous after a session dies, so a
  # lookup can briefly return a dead pid — treat it as gone.
  defp whereis(task_id) do
    case Registry.lookup(@registry, task_id) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid, else: nil
      [] -> nil
    end
  end

  defp start_session(%Task{target: :repo, repository_id: repository_id} = task, opts)
       when not is_nil(repository_id) do
    repository = Projects.get_repository!(repository_id)

    cond do
      is_nil(repository.preview_command) -> {:error, :no_preview_command}
      is_nil(task.worktree_path) -> {:error, :no_worktree}
      true -> start_session(task, repository.preview_command, opts)
    end
  end

  defp start_session(%Task{}, _opts), do: {:error, :no_preview_command}

  defp start_session(task, preview_command, opts) do
    env = session_env(task, opts)

    with {:ok, spec} <- spawn_spec(task, preview_command, env) do
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
      spec = %{
        task_id: task_id,
        port_opener: nil,
        stopper: container_stopper(container_id, pid_file(task_id)),
        probe: probe(task)
      }

      case DynamicSupervisor.start_child(@supervisor, {Session, spec}) do
        {:ok, _pid} ->
          Logger.info("adopted surviving preview server (task #{task_id}, pid #{pid})")

        _already_started_or_failed ->
          :ok
      end
    else
      _nothing_to_adopt -> :ok
    end
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
          [container_id, "sh", "-lc", wrap_command(preview_command, pid_file)]

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

  # `echo $$` before `exec` records the pid the command keeps — the
  # command should be a single process; installs belong in the
  # devcontainer's lifecycle hooks.
  defp wrap_command(preview_command, pid_file) do
    ~s(echo $$ > #{pid_file}; exec #{preview_command})
  end

  defp pid_file(task_id) do
    Path.join(Workspace.agent_home(task_id), "preview.pid")
  end

  # Readiness = the preview upstream accepts a TCP connection, resolved
  # through the same gateway the proxy uses (for container tasks this
  # also ensures the relay).
  defp probe(task) do
    fn ->
      with {:ok, %{host: host, port: port}} <- PreviewGateway.impl().upstream_for(task),
           {:ok, socket} <-
             :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 1_000) do
        :gen_tcp.close(socket)
        :ready
      else
        _not_yet -> :waiting
      end
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
