defmodule CodeLead.Git do
  @moduledoc """
  Porcelain over the `git` CLI for the managed workspace: base clones,
  per-task worktrees on feature branches, diffs against the branch
  base, push, and merging a finished branch into the default branch.
  All functions shell out via `System.cmd/3` and return
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

  # Git speaks English here — every invocation pins `LC_ALL=C` (see
  # `env_overrides/1`) precisely so these markers survive the operator's
  # locale.
  @auth_markers [
    "Repository not found",
    "Authentication failed",
    "could not read Username",
    "terminal prompts disabled",
    "Permission denied (publickey)",
    "Invalid username or token"
  ]

  # A read-only credential clones and fetches fine and only fails at
  # push, where the forge answers 403 instead of challenging the
  # credential. The remedy is a scope change rather than a new token, so
  # this cannot be folded into @auth_markers.
  @write_markers [
    "Write access to repository not granted",
    "You are not allowed to push code to this project"
  ]

  # Merging into the default branch fails in three ways the operator
  # fixes differently: rewrite the branch, retry, or stop merging
  # directly. None of them is a credential problem, which is why they
  # cannot be folded into `refusal/1`.
  @conflict_markers [
    "CONFLICT",
    "Automatic merge failed",
    "error: Your local changes",
    "would be overwritten by merge"
  ]

  @stale_markers [
    "non-fast-forward",
    "Updates were rejected",
    "fetch first",
    "! [rejected]"
  ]

  @protected_markers [
    "protected branch",
    "GH006",
    "pre-receive hook declined",
    "You are not allowed to push code to protected branches"
  ]

  # Every commit CodeLead makes is attributed to CodeLead rather than to
  # the operator's git identity, which the server may not even have.
  @identity_args ["-c", "user.name=CodeLead", "-c", "user.email=codelead@localhost"]

  # Answers only `get`, and reads the secret from the environment so the
  # token never appears in argv.
  @credential_helper ~S|!f() { test "$1" = get && echo username=x-access-token && | <>
                       ~S|echo "password=$CODELEAD_GIT_TOKEN"; }; f|

  @type forge :: {:github | :gitlab, String.t(), String.t()} | :other

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
           {:ok, _} <- fetch(path, opts) do
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
  Updates the remote-tracking refs, dropping ones the remote deleted.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch(repo_path, opts \\ []) do
    git(repo_path, ["fetch", "origin", "--prune"], opts)
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
  @spec forge(String.t()) :: forge()
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
  Adds a **detached** worktree at `worktree_path` on the tip of
  `base_branch` (preferring its origin-tracking ref) — read-only source
  to look at, with no branch to accidentally commit to.

  The base clone's own working tree is never updated after the initial
  clone (`ensure_clone/3` only fetches), so a worktree off the fetched
  ref is the way to read *current* default-branch source.
  """
  @spec create_detached_worktree(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def create_detached_worktree(base_clone_path, worktree_path, base_branch) do
    File.mkdir_p!(Path.dirname(worktree_path))
    start_point = preferred_start_point(base_clone_path, base_branch)

    with {:ok, _} <-
           git(base_clone_path, ["worktree", "add", "--detach", worktree_path, start_point]) do
      {:ok, worktree_path}
    end
  end

  @doc """
  Adds a worktree at `worktree_path` checking out the *existing*
  `branch` — the recovery path for a branch whose worktree directory is
  gone but whose commits are not.
  """
  @spec attach_worktree(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def attach_worktree(base_clone_path, worktree_path, branch) do
    File.mkdir_p!(Path.dirname(worktree_path))

    with {:ok, _} <- git(base_clone_path, ["worktree", "add", worktree_path, branch]) do
      {:ok, worktree_path}
    end
  end

  @doc """
  The branch checked out at `worktree_path`, if this clone registers a
  worktree there.

  `:error` covers every way the path is not ours: no directory, a
  directory this clone knows nothing about (a leftover from another
  clone or an earlier database generation), or a detached HEAD.
  """
  @spec worktree_branch(String.t(), String.t()) :: {:ok, String.t()} | :error
  def worktree_branch(base_clone_path, worktree_path) do
    wanted = Path.expand(worktree_path)

    case git(base_clone_path, ["worktree", "list", "--porcelain"]) do
      {:ok, output} ->
        output
        |> String.split(~r/\n\s*\n/, trim: true)
        |> Enum.find_value(:error, &registered_branch(&1, wanted))

      {:error, _output} ->
        :error
    end
  end

  @doc """
  Removes a worktree and prunes stale registrations. Removal is
  verified: a directory that survives (root-owned files, a base clone
  that cannot answer) is reported, not swallowed. Pruning only runs on
  verified removal — `worktree prune` is repository-wide, and running
  it while a sibling worktree is unreachable drops that sibling's
  registration too.
  """
  @spec remove_worktree(String.t(), String.t()) :: :ok | {:error, {:leftover, String.t()}}
  def remove_worktree(base_clone_path, worktree_path) do
    _ = git(base_clone_path, ["worktree", "remove", "--force", worktree_path])
    _ = CodeLead.Workspace.Remover.remove_dir(worktree_path)

    if File.exists?(worktree_path) do
      {:error, {:leftover, worktree_path}}
    else
      _ = git(base_clone_path, ["worktree", "prune"])
      :ok
    end
  end

  @spec delete_branch(String.t(), String.t()) :: :ok
  def delete_branch(base_clone_path, branch) do
    _ = git(base_clone_path, ["branch", "-D", branch])
    :ok
  end

  @doc """
  Heals the gitdir cross-pointers between a base clone and its
  worktrees after the workspace root moved. With explicit paths git
  repairs both link directions; the output names what was rewritten
  (empty when everything already pointed right).
  """
  @spec repair_worktrees(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def repair_worktrees(base_clone_path, worktree_paths) do
    git(base_clone_path, ["worktree", "repair" | worktree_paths])
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
    with {:ok, _} <- git(worktree_path, ["add", "-A"]) do
      commit_staged(worktree_path, message)
    end
  end

  @doc """
  Merges `ref` into whatever is checked out at `worktree_path`.

  `:strategy` is `:merge` for a `--no-ff` merge commit or `:squash` for
  a single commit carrying the whole branch; `:message` names the commit.
  `:noop` means the ref contributed nothing — an approve after the work
  already landed, not a failure.

  A conflict leaves the worktree mid-merge. Callers work in a disposable
  worktree and delete it, which is both simpler and safer than
  `merge --abort`.
  """
  @spec merge(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | :noop | {:error, String.t()}
  def merge(worktree_path, ref, opts \\ []) do
    message = Keyword.get(opts, :message, "CodeLead: merge #{ref}")

    case Keyword.get(opts, :strategy, :merge) do
      :squash ->
        with {:ok, _} <- git(worktree_path, ["merge", "--squash", ref]) do
          commit_staged(worktree_path, message)
        end

      :merge ->
        worktree_path
        |> git(@identity_args ++ ["merge", "--no-ff", "-m", message, ref])
        |> merge_result()
    end
  end

  @spec push(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def push(worktree_path, branch, opts \\ []) do
    git(worktree_path, ["push", "-u", "origin", branch], opts)
  end

  @doc """
  Pushes a local ref to a differently-named remote branch (`HEAD:main`).

  Never forced: a rejection means the remote branch moved under us, and
  overwriting it would discard whatever moved it.
  """
  @spec push_ref(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def push_ref(repo_path, source_ref, dest_branch, opts \\ []) do
    git(repo_path, ["push", "origin", "#{source_ref}:#{dest_branch}"], opts)
  end

  @doc """
  Deletes a branch from the remote — the feature branch after its work
  has been merged.
  """
  @spec delete_remote_branch(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def delete_remote_branch(repo_path, branch, opts \\ []) do
    git(repo_path, ["push", "origin", "--delete", branch], opts)
  end

  @doc """
  The commit currently checked out — what a merge produced, so it can be
  linked.
  """
  @spec head_sha(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def head_sha(repo_path) do
    with {:ok, sha} <- git(repo_path, ["rev-parse", "HEAD"]), do: {:ok, String.trim(sha)}
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
  Classifies a git failure by what the operator has to change: the
  credential itself, its write scope, or something that is not about
  credentials at all.
  """
  @spec refusal(String.t()) :: :auth | :write_denied | :other
  def refusal(output) do
    cond do
      String.contains?(output, @write_markers) -> :write_denied
      String.contains?(output, @auth_markers) -> :auth
      true -> :other
    end
  end

  @doc """
  Explains a failure against a remote in operator terms — what to change
  and where — followed by the line git printed. `action` names what was
  attempted ("prepare the workspace", "push the branch"); the caller
  resolves the forge and whether a token was presented, because only it
  knows. The detail is redacted, so the result is safe to flash and to
  persist.
  """
  @spec remote_failure(String.t(), String.t(), forge(), boolean()) :: String.t()
  def remote_failure(action, output, forge, token_present?) do
    detail = output |> failure_reason() |> redact()

    case {refusal(output), forge, token_present?} do
      {:other, _forge, _present?} ->
        "could not #{action}: #{detail}"

      {_refusal, :other, _present?} ->
        "could not #{action}; this remote has no token convention, so the " <>
          "server's own git credentials were used: #{detail}"

      {:write_denied, {kind, owner, repo}, true} ->
        "the #{token_var(kind)} in the project env store can read #{owner}/#{repo} " <>
          "but not write to it — grant it #{write_scope(kind)} on #{host(kind)}: #{detail}"

      {:write_denied, {kind, _owner, _repo}, false} ->
        "the git credentials the server fell back on cannot write to this " <>
          "repository — add a #{token_var(kind)} with write access to the " <>
          "project env store: #{detail}"

      {:auth, {kind, owner, repo}, true} ->
        "the #{token_var(kind)} in the project env store was rejected by " <>
          "#{host(kind)} — check that it has not expired and grants access to " <>
          "#{owner}/#{repo}: #{detail}"

      {:auth, {kind, _owner, _repo}, false} ->
        "could not #{action} — add a #{token_var(kind)} to the " <>
          "project env store: #{detail}"
    end
  end

  @doc """
  Classifies why merging into the default branch failed, by what the
  operator has to do about it: rewrite the branch, retry, stop pushing
  directly — or something that is not merge-specific at all.
  """
  @spec merge_refusal(String.t()) :: :conflict | :non_fast_forward | :protected | :other
  def merge_refusal(output) do
    cond do
      String.contains?(output, @conflict_markers) -> :conflict
      String.contains?(output, @protected_markers) -> :protected
      String.contains?(output, @stale_markers) -> :non_fast_forward
      true -> :other
    end
  end

  @doc """
  Explains a failed merge into `base_branch` in operator terms, naming
  the remedy. Anything that is not merge-specific — a rejected or
  read-only credential — falls through to `remote_failure/4`, which
  already knows what to say about it.
  """
  @spec merge_failure(String.t(), String.t(), forge(), boolean()) :: String.t()
  def merge_failure(base_branch, output, forge, token_present?) do
    detail = output |> failure_reason() |> redact()

    case merge_refusal(output) do
      :conflict ->
        "the feature branch conflicts with #{base_branch} — nothing was merged. " <>
          "Request changes so the agent rebases, or switch this task to Pull " <>
          "request mode and resolve it on the forge: #{detail}"

      :non_fast_forward ->
        "#{base_branch} moved on the remote while the merge ran, so nothing " <>
          "was pushed — approve again to retry against its new tip: #{detail}"

      :protected ->
        "the remote refuses direct pushes to #{base_branch} (protected " <>
          "branch) — switch this task's finalize mode to Pull request: #{detail}"

      :other ->
        remote_failure("merge into #{base_branch}", output, forge, token_present?)
    end
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

  # Committing an empty index is an error in git and a no-op in intent,
  # so emptiness is checked rather than caught. Shared by `commit_all/2`
  # and the squash strategy, which stage differently but commit alike.
  defp commit_staged(worktree_path, message) do
    with {:ok, status} <- git(worktree_path, ["status", "--porcelain"]) do
      if String.trim(status) == "" do
        :noop
      else
        git(worktree_path, @identity_args ++ ["commit", "-m", message])
      end
    end
  end

  # A merge that changes nothing succeeds, so "nothing to do" has to be
  # read out of the message rather than off the exit status.
  defp merge_result({:ok, output}) do
    if String.contains?(output, "Already up to date"), do: :noop, else: {:ok, output}
  end

  defp merge_result(error), do: error

  defp write_scope(:github), do: "Contents: Read and write"
  defp write_scope(:gitlab), do: "the write_repository scope"

  # One `--porcelain` block: a `worktree` line, then `HEAD`, then either
  # `branch refs/heads/<name>` or the bare word `detached`.
  defp registered_branch(block, wanted) do
    lines = String.split(block, "\n", trim: true)

    with ["worktree " <> path] <- Enum.filter(lines, &String.starts_with?(&1, "worktree ")),
         true <- Path.expand(String.trim(path)) == wanted,
         ["branch refs/heads/" <> branch] <-
           Enum.filter(lines, &String.starts_with?(&1, "branch refs/heads/")) do
      {:ok, String.trim(branch)}
    else
      _other -> nil
    end
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
