defmodule CodeLead.Git do
  @moduledoc """
  Porcelain over the `git` CLI for the managed workspace: base clones,
  per-task worktrees on feature branches, diffs against the branch
  base, and push. All functions shell out via `System.cmd/3` and return
  `{:ok, output}` / `{:error, output}`.
  """

  @doc """
  Clones `git_url` to `path` unless the clone already exists; fetches
  origin when it does.
  """
  @spec ensure_clone(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def ensure_clone(git_url, path) do
    if File.dir?(Path.join(path, ".git")) do
      with {:ok, _} <- git(path, ["fetch", "origin", "--prune"]), do: {:ok, path}
    else
      File.mkdir_p!(Path.dirname(path))

      case run(["clone", git_url, path]) do
        {:ok, _} -> {:ok, path}
        error -> error
      end
    end
  end

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
  """
  @spec diff(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(worktree_path, base_branch) do
    with {:ok, base} <- merge_base(worktree_path, base_branch),
         {:ok, _} <- git(worktree_path, ["add", "-A", "-N"]) do
      git(worktree_path, ["diff", base])
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

  @spec push(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def push(worktree_path, branch) do
    git(worktree_path, ["push", "-u", "origin", branch])
  end

  @doc """
  Lists branch names on the remote — used to verify pushes and build
  compare links.
  """
  @spec remote_branches(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def remote_branches(repo_path) do
    with {:ok, output} <- git(repo_path, ["ls-remote", "--heads", "origin"]) do
      branches =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> String.split("refs/heads/") |> List.last() end)

      {:ok, branches}
    end
  end

  @doc """
  Runs a git subcommand in `repo_path`.
  """
  @spec git(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def git(repo_path, args) do
    run(["-C", repo_path | args])
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

  defp preferred_start_point(base_clone_path, base_branch) do
    case git(base_clone_path, ["rev-parse", "--verify", "origin/#{base_branch}"]) do
      {:ok, _} -> "origin/#{base_branch}"
      {:error, _} -> base_branch
    end
  end

  defp run(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, output}
    end
  end
end
