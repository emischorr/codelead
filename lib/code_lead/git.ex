defmodule CodeLead.Git do
  @moduledoc """
  Porcelain over the `git` CLI for the managed workspace: base clones,
  per-task worktrees on feature branches, diffs against the branch
  base, and push. All functions shell out via `System.cmd/3` and return
  `{:ok, output}` / `{:error, output}`.

  ## Credentials

  Functions that touch a remote take a `:token` option — a forge access
  token, resolved by the caller from the project env store. It reaches
  git through a per-invocation `credential.helper` that reads it back
  out of the subprocess environment, so it never lands in `.git/config`,
  in argv, or anywhere on disk. The helper answers with the username
  `x-access-token`; both GitHub and GitLab ignore it and authenticate on
  the token alone.

  Without a `:token` no helper is installed at all, so git falls back to
  the server's ambient credentials — the operator's keychain on a dev
  laptop, nothing at all in a container. A repository can therefore clone
  fine until a token is added and then start failing, because installing
  the helper also resets the inherited ones.

  Every invocation, remote or not, runs with a sanitized environment:
  the askpass hooks a launching terminal may have injected are unset and
  interactive prompting is disabled, so git fails fast instead of
  hanging or popping a dialog on the operator's desktop.
  """

  # A redacted detail may be persisted forever; a secret must never reach
  # one.
  @token_patterns [
    ~r/\bgh[pousr]_[A-Za-z0-9]{16,}/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{16,}/,
    ~r/\bglpat-[A-Za-z0-9\-_]{16,}/
  ]
  @userinfo_pattern ~r{(https?://)[^\s/:@]+:[^\s/@]+@}

  # Answers only `get`, and reads the secret from the environment so the
  # token never appears in argv.
  @credential_helper ~S|!f() { test "$1" = get && echo username=x-access-token && | <>
                       ~S|echo "password=$CODELEAD_GIT_TOKEN"; }; f|

  @doc """
  Clones `git_url` to `path` unless the clone already exists; re-points
  `origin` at `git_url` and fetches when it does, so editing a project's
  repository URL takes effect on the existing clone.
  """
  @spec ensure_clone(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def ensure_clone(git_url, path, opts \\ []) do
    if File.dir?(Path.join(path, ".git")) do
      with {:ok, _} <- git(path, ["remote", "set-url", "origin", git_url], opts),
           {:ok, _} <- git(path, ["fetch", "origin", "--prune"], opts) do
        {:ok, path}
      end
    else
      File.mkdir_p!(Path.dirname(path))

      case run(["clone", git_url, path], opts) do
        {:ok, _} -> {:ok, path}
        error -> error
      end
    end
  end

  @doc """
  Probes whether the remote is reachable with the given credentials,
  without cloning anything.
  """
  @spec check_access(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_access(git_url, opts \\ []) do
    with {:ok, _} <- run(["ls-remote", "--heads", git_url], opts), do: :ok
  end

  @doc """
  Classifies a git remote URL: `{:github, owner, repo}`,
  `{:gitlab, owner, repo}`, or `:other`.
  """
  @spec forge(String.t()) :: {:github | :gitlab, String.t(), String.t()} | :other
  def forge(git_url) do
    case Regex.run(
           ~r{(?:https://|git@)(github\.com|gitlab\.com)[:/]([^/]+)/(.+?)(?:\.git)?/?$},
           git_url
         ) do
      ["" <> _match, "github.com", owner, repo] -> {:github, owner, repo}
      [_match, "gitlab.com", owner, repo] -> {:gitlab, owner, repo}
      _no_match -> :other
    end
  end

  @doc """
  The project env store key holding the access token for a forge.
  """
  @spec token_var(:github | :gitlab) :: String.t()
  def token_var(:github), do: "GITHUB_TOKEN"
  def token_var(:gitlab), do: "GITLAB_TOKEN"

  @doc """
  The host a forge is served from — for naming it in operator-facing
  messages.
  """
  @spec host(:github | :gitlab) :: String.t()
  def host(:github), do: "github.com"
  def host(:gitlab), do: "gitlab.com"

  @doc """
  Adds a worktree at `worktree_path` on new branch `branch` starting
  from `base_branch` (preferring its origin-tracking ref).
  """
  @spec create_worktree(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def create_worktree(base_clone_path, worktree_path, branch, base_branch) do
    File.mkdir_p!(Path.dirname(worktree_path))
    start_point = preferred_start_point(base_clone_path, base_branch)

    with {:ok, _} <-
           git(base_clone_path, ["worktree", "add", "-b", branch, worktree_path, start_point]) do
      {:ok, worktree_path}
    end
  end

  @doc """
  Removes a worktree and prunes stale registrations.
  """
  @spec remove_worktree(String.t(), String.t()) :: :ok
  def remove_worktree(base_clone_path, worktree_path) do
    _ = git(base_clone_path, ["worktree", "remove", "--force", worktree_path])
    _ = File.rm_rf(worktree_path)
    _ = git(base_clone_path, ["worktree", "prune"])
    :ok
  end

  @spec delete_branch(String.t(), String.t()) :: :ok
  def delete_branch(base_clone_path, branch) do
    _ = git(base_clone_path, ["branch", "-D", branch])
    :ok
  end

  @doc """
  Full delta of the worktree (committed + uncommitted, untracked files
  included via intent-to-add) against the branch base on `base_branch`.

  Never mutates the worktree's own index — the intent-to-add pass runs
  against a throwaway copy — so it is safe to call repeatedly while an
  agent is working in the same worktree.
  """
  @spec diff(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(worktree_path, base_branch) do
    scratch = scratch_index_path()

    try do
      with {:ok, base} <- merge_base(worktree_path, base_branch),
           :ok <- seed_scratch_index(worktree_path, scratch),
           env = [{"GIT_INDEX_FILE", scratch}],
           {:ok, _} <- git(worktree_path, ["add", "-A", "-N"], env: env) do
        git(worktree_path, ["diff", base], env: env)
      end
    after
      File.rm(scratch)
      File.rm(scratch <> ".lock")
    end
  end

  @doc """
  Stages and commits everything in the worktree. Returns `:noop` when
  there is nothing to commit.
  """
  @spec commit_all(String.t(), String.t()) :: {:ok, String.t()} | :noop | {:error, String.t()}
  def commit_all(worktree_path, message) do
    with {:ok, _} <- git(worktree_path, ["add", "-A"]),
         {:ok, status} <- git(worktree_path, ["status", "--porcelain"]) do
      if String.trim(status) == "" do
        :noop
      else
        git(worktree_path, [
          "-c",
          "user.name=CodeLead",
          "-c",
          "user.email=codelead@localhost",
          "commit",
          "-m",
          message
        ])
      end
    end
  end

  @spec push(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def push(worktree_path, branch, opts \\ []) do
    git(worktree_path, ["push", "-u", "origin", branch], opts)
  end

  @doc """
  Lists branch names on the remote — used to verify pushes and build
  compare links.
  """
  @spec remote_branches(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def remote_branches(repo_path, opts \\ []) do
    with {:ok, output} <- git(repo_path, ["ls-remote", "--heads", "origin"], opts) do
      branches =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> String.split("refs/heads/") |> List.last() end)

      {:ok, branches}
    end
  end

  @doc """
  Strips anything that looks like a credential out of a failure detail.
  Git output is persisted to `task_steps` and shown in the UI, and both
  outlive the secret.
  """
  @spec redact(String.t()) :: String.t()
  def redact(detail) do
    @token_patterns
    |> Enum.reduce(detail, &Regex.replace(&1, &2, "[REDACTED]"))
    |> then(&Regex.replace(@userinfo_pattern, &1, "\\1[REDACTED]@"))
  end

  @doc """
  The line of a git failure that carries the reason — a remote's refusal
  or a fatal — falling back to the last line of output.
  """
  @spec failure_reason(String.t()) :: String.t()
  def failure_reason(output) do
    lines =
      output
      |> String.split(["\n", "\r"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Enum.find(
      lines,
      List.last(lines) || "",
      &String.starts_with?(&1, ["fatal:", "error:", "remote:"])
    )
  end

  @doc """
  Runs a git subcommand in `repo_path`. Options: `:token` for a forge
  credential, `:env` for extra environment variables layered on top of
  `env_overrides/1`.
  """
  @spec git(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def git(repo_path, args, opts \\ []) do
    run(["-C", repo_path | args], opts)
  end

  @doc """
  Environment overrides applied to every git invocation. A `nil` value
  unsets the variable for the subprocess.
  """
  @spec env_overrides(String.t() | nil) :: [{String.t(), String.t() | nil}]
  def env_overrides(token) do
    [
      {"CODELEAD_GIT_TOKEN", token},
      # Fail fast instead of prompting: there is no terminal to answer on.
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_SSH_COMMAND", "ssh -o BatchMode=yes"},
      # Parseable, loggable error text regardless of the host locale.
      {"LC_ALL", "C"},
      # Neutralize the launching terminal. A VS Code integrated terminal
      # injects these, which is how a clone ends up asking the operator's
      # desktop for GitHub credentials.
      {"GIT_ASKPASS", nil},
      {"SSH_ASKPASS", nil},
      {"GIT_CONFIG_PARAMETERS", nil},
      {"VSCODE_GIT_ASKPASS_NODE", nil},
      {"VSCODE_GIT_ASKPASS_MAIN", nil},
      {"VSCODE_GIT_ASKPASS_EXTRA_ARGS", nil},
      {"VSCODE_GIT_IPC_HANDLE", nil}
    ]
  end

  @doc """
  The `-c` overrides that install the ephemeral credential helper.
  Exposed for tests; callers pass `:token` instead.
  """
  @spec credential_args(String.t() | nil) :: [String.t()]
  def credential_args(nil), do: []

  def credential_args(_token) do
    [
      # The empty value first resets helpers inherited from ~/.gitconfig
      # (osxkeychain and friends) so ours is the only one consulted.
      "-c",
      "credential.helper=",
      "-c",
      "credential.helper=" <> @credential_helper
    ]
  end

  defp merge_base(worktree_path, base_branch) do
    case git(worktree_path, ["merge-base", "HEAD", "origin/#{base_branch}"]) do
      {:ok, sha} ->
        {:ok, String.trim(sha)}

      {:error, _} ->
        with {:ok, sha} <- git(worktree_path, ["merge-base", "HEAD", base_branch]),
             do: {:ok, String.trim(sha)}
    end
  end

  # Copying the real index carries its stat cache over, so `add -A` only
  # hashes what actually changed instead of walking the whole tree. When
  # there is no index to copy, HEAD is a correct — merely slower —
  # starting point.
  defp seed_scratch_index(worktree_path, scratch) do
    with {:ok, relative} <- git(worktree_path, ["rev-parse", "--git-path", "index"]),
         source = Path.expand(String.trim(relative), worktree_path),
         {:error, _reason} <- File.cp(source, scratch) do
      read_tree(worktree_path, scratch)
    end
  end

  defp read_tree(worktree_path, scratch) do
    with {:ok, _} <-
           git(worktree_path, ["read-tree", "HEAD"], env: [{"GIT_INDEX_FILE", scratch}]),
         do: :ok
  end

  defp scratch_index_path do
    unique = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "codelead-diff-#{unique}.index")
  end

  defp preferred_start_point(base_clone_path, base_branch) do
    case git(base_clone_path, ["rev-parse", "--verify", "origin/#{base_branch}"]) do
      {:ok, _} -> "origin/#{base_branch}"
      {:error, _} -> base_branch
    end
  end

  defp run(args, opts) do
    token = Keyword.get(opts, :token)

    case System.cmd("git", credential_args(token) ++ args,
           stderr_to_stdout: true,
           env: env_overrides(token) ++ Keyword.get(opts, :env, [])
         ) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output}
    end
  end
end
