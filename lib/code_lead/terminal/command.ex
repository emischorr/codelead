defmodule CodeLead.Terminal.Command do
  @moduledoc """
  Pure spawn-spec builders for terminal sessions. Erlang ports have no
  TTY, so a PTY can only be allocated *inside* the spawned context —
  util-linux/BSD `script(1)` does exactly that. When `script` is
  missing (host or image), the fallback is a plain `sh -i` pipe:
  degraded (no echo, no line editing) but enough to start a dev server
  and watch its logs.
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
    {script_path, ["-q", "/dev/null", shell], true}
  end

  def local(:linux, shell, script_path) when is_binary(script_path) do
    # util-linux form: script -qec <command> [file]
    {script_path, ["-qec", shell, "/dev/null"], true}
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

  defp shell_argv(shell, true), do: ["script", "-qec", shell, "/dev/null"]
  defp shell_argv(shell, false), do: [shell, "-i"]
end
