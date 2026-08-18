defmodule CodeLead.Terminal.Command do
  @moduledoc """
  Pure spawn-spec builders for terminal sessions. Erlang ports have no
  TTY, so a PTY can only be allocated *inside* the spawned context —
  util-linux/BSD `script(1)` does exactly that. When `script` is
  missing (host or image), the fallback is a plain `sh -i` pipe:
  degraded (no echo, no line editing) but enough to start a dev server
  and watch its logs.

  The PTY forms do not run the shell directly but `payload/1`, which
  records the allocated PTY's device path in `$CODELEAD_TTY_FILE` and
  applies the initial size before `exec`ing the shell. That file is the
  resize channel: `resize_script/4` targets the device from *outside*
  the session, which is the only way to reach `TIOCSWINSZ` when the
  spawning side has no TTY of its own (ADR-0010).
  """

  @doc """
  Local spawn spec: `{executable, args, pty?}`. `script_path` is the
  resolved `script(1)` binary or nil; `shell` may be a bare name (the
  PTY forms resolve it via PATH inside `script`), but must be absolute
  when it becomes the executable itself.
  """
  @spec local(:darwin | :linux | atom(), String.t(), String.t() | nil) ::
          {String.t(), [String.t()], boolean()}
  def local(:darwin, shell, script_path) when is_binary(script_path) do
    # BSD form: script -q [file] [command...]
    {script_path, ["-q", "/dev/null", shell, "-c", payload(shell)], true}
  end

  def local(:linux, shell, script_path) when is_binary(script_path) do
    # util-linux form: script -qec <command> [file]
    {script_path, ["-qec", payload(shell), "/dev/null"], true}
  end

  def local(_os, shell, _script_path), do: {shell, ["-i"], false}

  @doc """
  Argv for a `docker exec` terminal into a task container (everything
  after the docker CLI executable). `env_flags` are the prebuilt `-e`
  pairs; `script?` says whether the image carries `script(1)`.
  """
  @spec docker([String.t()], String.t(), String.t(), [String.t()], String.t(), boolean()) ::
          [String.t()]
  def docker(prefix, container, workdir, env_flags, shell, script?) do
    prefix ++
      ["exec", "-i", "-w", workdir] ++ env_flags ++ [container | shell_argv(shell, script?)]
  end

  @doc """
  Shell command that resizes an already-running session's PTY, reading
  the device path from the file `payload/1` recorded. Runs in the same
  context as the session (the host for local tasks, `docker exec` for
  container ones), so the path resolves and the device is reachable.

  Selecting a device is the one thing POSIX leaves out of `stty`:
  util-linux spells it `-F`, BSD `-f`. Which one answers depends on the
  binary that happens to be on PATH, not on the OS — a macOS host with
  GNU coreutils installed wants `-F` — so both are tried.
  """
  @spec resize_script(String.t(), pos_integer(), pos_integer()) :: String.t()
  def resize_script(tty_file, cols, rows) do
    # `read` rather than `$(cat …)`: no subshell, and a missing file
    # short-circuits the `&&` instead of resizing whatever "" resolves to.
    ~s(read -r tty < "#{tty_file}" && ) <>
      ~s({ stty -F "$tty" #{size_args(cols, rows)} 2>/dev/null || ) <>
      ~s(stty -f "$tty" #{size_args(cols, rows)}; })
  end

  @doc """
  The shell command string the PTY forms run instead of the bare shell.
  Recording the device path is best-effort: every step is silenced and
  the shell is `exec`ed regardless, so a context without `tty`, `stty`,
  or a writable `$CODELEAD_TTY_FILE` still gets a working terminal —
  just no live resize.
  """
  @spec payload(String.t()) :: String.t()
  def payload(shell) do
    # `${var%/*}` rather than `$(dirname …)`: parameter expansion keeps
    # the whole payload free of nested parens and subshells.
    ~s(mkdir -p "${CODELEAD_TTY_FILE%/*}" 2>/dev/null; ) <>
      ~s(tty > "$CODELEAD_TTY_FILE" 2>/dev/null; ) <>
      ~s(stty rows "$LINES" cols "$COLUMNS" 2>/dev/null; ) <>
      ~s(exec #{shell} -i)
  end

  defp size_args(cols, rows), do: "rows #{rows} cols #{cols}"

  defp shell_argv(shell, true), do: ["script", "-qec", payload(shell), "/dev/null"]
  defp shell_argv(shell, false), do: [shell, "-i"]
end
