defmodule CodeLead.Terminal do
  @moduledoc """
  Interactive terminals into a task's execution context — the surface
  behind the task page's Terminal tab. One `Session` per task owns the
  shell Port and survives page refreshes; viewers attach/detach and
  receive output over PubSub (`"terminal:<task_id>"`, messages
  `{:terminal_data, task_id, chunk}` / `{:terminal_exit, task_id,
  status}`).

  Local tasks get a host shell in their execution context — the
  worktree for repo targets, the task folder for folder ones; container
  tasks a `docker exec` shell into the task's devcontainer (self-healing
  via `Devcontainer.ensure_for_task/1`, licensed like every container
  exec). PTY where `script(1)` exists, plain pipe otherwise
  (`CodeLead.Terminal.Command`).
  """

  alias CodeLead.Executor.Devcontainer
  alias CodeLead.Executor.DockerCli
  alias CodeLead.Executor.EnvScrub
  alias CodeLead.License
  alias CodeLead.Projects
  alias CodeLead.Terminal.Command
  alias CodeLead.Terminal.Session
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace

  @registry CodeLead.Terminal.Registry
  @supervisor CodeLead.Terminal.SessionSupervisor
  @default_idle_ms 15 * 60_000

  @doc """
  The task's live session, starting one if needed. `opts`: `:cols` /
  `:rows` (initial size — exported as COLUMNS/LINES and applied to the
  PTY by the spawn payload) and `:extra_env` (pre-computed pairs such as
  PREVIEW_BASE_PATH — the caller owns any cross-domain lookups).
  """
  @spec ensure_session(Task.t(), keyword()) ::
          {:ok, pid()} | {:error, :no_context | :container_unlicensed | term()}
  def ensure_session(%Task{} = task, opts \\ []) do
    case whereis(task.id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_session(task, opts)
    end
  end

  @doc """
  The directory a terminal opens in, or nil when the task has no
  execution context yet. Repo targets get the provisioned worktree;
  folder targets the task folder, which is derived from the id rather
  than persisted — but only once a run has actually created it.
  """
  @spec context_path(Task.t()) :: String.t() | nil
  def context_path(%Task{target: :folder, id: id}) do
    path = Workspace.task_folder(id)
    if File.dir?(path), do: path
  end

  def context_path(%Task{worktree_path: worktree_path}), do: worktree_path

  @doc """
  Attaches the calling process as a viewer (monitored; a crashed viewer
  detaches implicitly) and returns the scrollback to repaint from.
  """
  @spec attach(pos_integer()) ::
          {:ok, scrollback :: binary(), pty? :: boolean()} | {:error, :not_running}
  def attach(task_id) do
    call(task_id, {:attach, self()})
  end

  @spec detach(pos_integer()) :: :ok
  def detach(task_id) do
    case call(task_id, {:detach, self()}) do
      {:error, :not_running} -> :ok
      :ok -> :ok
    end
  end

  @doc """
  Raw bytes for the shell's stdin — keystrokes, exactly as typed.
  """
  @spec send_input(pos_integer(), binary()) :: :ok
  def send_input(task_id, data) do
    case whereis(task_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:input, data})
    end
  end

  @doc """
  Applies a new window size to the session's PTY. Best-effort: sessions
  without a PTY, or contexts where the device path was never recorded,
  ignore it silently (`CodeLead.Terminal.Command`).
  """
  @spec resize(pos_integer(), pos_integer(), pos_integer()) :: :ok
  def resize(task_id, cols, rows) when cols > 0 and rows > 0 do
    case whereis(task_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:resize, cols, rows})
    end
  end

  @spec alive?(pos_integer()) :: boolean()
  def alive?(task_id), do: whereis(task_id) != nil

  @spec subscribe(pos_integer()) :: :ok | {:error, term()}
  def subscribe(task_id) do
    Phoenix.PubSub.subscribe(CodeLead.PubSub, topic(task_id))
  end

  @doc false
  @spec broadcast(pos_integer(), term()) :: :ok
  def broadcast(task_id, message) do
    Phoenix.PubSub.broadcast(CodeLead.PubSub, topic(task_id), message)
  end

  @doc false
  @spec via(pos_integer()) :: {:via, Registry, {module(), pos_integer()}}
  def via(task_id), do: {:via, Registry, {@registry, task_id}}

  @doc false
  @spec idle_ms() :: pos_integer()
  def idle_ms, do: Application.get_env(:code_lead, :terminal_idle_ms, @default_idle_ms)

  @spec child_specs() :: [Supervisor.child_spec() | {module(), term()}]
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]
  end

  defp topic(task_id), do: "terminal:#{task_id}"

  # Registry unregistration is asynchronous after a session dies, so a
  # lookup can briefly return a dead pid — treat it as gone.
  defp whereis(task_id) do
    case Registry.lookup(@registry, task_id) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid, else: nil
      [] -> nil
    end
  end

  defp call(task_id, message) do
    case whereis(task_id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, message, 30_000)
    end
  end

  defp start_session(task, opts) do
    case context_path(task) do
      nil -> {:error, :no_context}
      path -> start_session(task, path, opts)
    end
  end

  defp start_session(task, path, opts) do
    with {:ok, spec} <- spawn_spec(task, path, opts) do
      case DynamicSupervisor.start_child(@supervisor, {Session, spec}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        error -> error
      end
    end
  end

  # `tty_file` is where the session records the PTY device it was given,
  # so a later resize can reach it from outside (ADR-0010). It must be
  # writable *inside* the execution context: the host temp dir for local
  # tasks, the per-task TMPDIR `Devcontainer.exec_flags/3` guarantees for
  # container ones.
  defp session_env(task, tty_file, opts) do
    Projects.env_vars(task.project_id) ++
      Keyword.get(opts, :extra_env, []) ++
      [
        {"TERM", "xterm-256color"},
        {"COLUMNS", to_string(Keyword.get(opts, :cols, 80))},
        {"LINES", to_string(Keyword.get(opts, :rows, 24))},
        {"CODELEAD_TTY_FILE", tty_file}
      ]
  end

  defp spawn_spec(%Task{target: :repo, execution_env: :container} = task, path, opts) do
    tty_file = Path.join([Workspace.agent_home(task.id), ".tmp", "codelead-tty"])
    env = session_env(task, tty_file, opts)

    with :ok <- check_container_license(),
         {:ok, container_id} <- Devcontainer.ensure_for_task(task.id),
         {:ok, {cli_path, prefix}} <- DockerCli.cli() do
      script? = container_has_script?(container_id)
      exec_flags = Devcontainer.exec_flags(task.id, container_id, env)
      args = Command.docker(prefix, container_id, path, exec_flags, shell(), script?)

      {:ok,
       %{
         task_id: task.id,
         pty?: script?,
         port_opener: fn -> open_port(cli_path, args, []) end,
         resizer: fn cols, rows ->
           script = Command.resize_script(tty_file, cols, rows)
           DockerCli.run(["exec", container_id, "sh", "-c", script])
         end
       }}
    end
  end

  defp spawn_spec(%Task{} = task, path, opts) do
    tty_file = Path.join(System.tmp_dir!(), "codelead-tty-#{task.id}")
    port_env = EnvScrub.port_env(session_env(task, tty_file, opts))

    with {:ok, {exe, args, pty?}} <- local_command() do
      {:ok,
       %{
         task_id: task.id,
         pty?: pty?,
         port_opener: fn ->
           # Clear a previous session's device before this one records
           # its own: host pts numbers are reused, so a resize landing in
           # the gap could otherwise reach an unrelated terminal.
           File.rm(tty_file)
           open_port(exe, args, cd: path, env: port_env)
         end,
         resizer: fn cols, rows ->
           System.cmd("sh", ["-c", Command.resize_script(tty_file, cols, rows)],
             stderr_to_stdout: true
           )
         end
       }}
    end
  end

  # The whole-argv test seam, mirroring `:docker_cli` — points at a
  # scripted fake shell so Session tests never spawn a real one.
  defp local_command do
    case Application.get_env(:code_lead, :terminal_command) do
      [exe | args] ->
        {:ok, {exe, args, false}}

      nil ->
        case System.find_executable(shell()) do
          nil -> {:error, {:shell_not_found, shell()}}
          shell_path -> {:ok, Command.local(os(), shell_path, System.find_executable("script"))}
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

  defp container_has_script?(name) do
    match?({:ok, _path}, DockerCli.run(["exec", name, "sh", "-c", "command -v script"]))
  end

  defp shell, do: Application.get_env(:code_lead, :terminal_shell, "sh")

  defp os do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, _linux_or_bsd} -> :linux
      _other -> :unknown
    end
  end
end
