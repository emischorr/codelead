defmodule CodeLead.GitTest do
  use ExUnit.Case, async: true

  alias CodeLead.Git
  alias CodeLead.GitHelpers

  describe "forge/1" do
    test "classifies remotes" do
      assert Git.forge("https://github.com/acme/site.git") == {:github, "acme", "site"}
      assert Git.forge("git@github.com:acme/site.git") == {:github, "acme", "site"}
      assert Git.forge("https://gitlab.com/acme/site") == {:gitlab, "acme", "site"}
      assert Git.forge("file:///tmp/origin.git") == :other
      assert Git.forge("https://git.example.com/acme/site.git") == :other
    end
  end

  describe "token_var/1" do
    test "names the project env key per forge" do
      assert Git.token_var(:github) == "GITHUB_TOKEN"
      assert Git.token_var(:gitlab) == "GITLAB_TOKEN"
    end
  end

  describe "host/1" do
    test "names the host per forge" do
      assert Git.host(:github) == "github.com"
      assert Git.host(:gitlab) == "gitlab.com"
    end
  end

  describe "failure_reason/1" do
    test "prefers the remote's refusal over git's progress chatter" do
      output = """
      Cloning into '/workspace/repos/assistant-1'...
      remote: Invalid username or token.
      fatal: Authentication failed for 'https://github.com/acme/assistant/'
      """

      assert Git.failure_reason(output) == "remote: Invalid username or token."
    end

    test "falls back to the last line when nothing is tagged" do
      assert Git.failure_reason("first\nlast\n") == "last"
      assert Git.failure_reason("") == ""
    end
  end

  describe "redact/1" do
    test "scrubs forge tokens" do
      refute Git.redact("fatal: bad credentials ghp_abcdefghijklmnopqrstuvwxyz012345") =~
               "ghp_abcdefghij"

      refute Git.redact("token github_pat_11ABCDEFG0abcdefghijklmnop") =~ "github_pat_11A"
      refute Git.redact("token glpat-abcdefghijklmnopqrst") =~ "glpat-abcdefghij"
    end

    test "scrubs credentials embedded in a URL" do
      redacted = Git.redact("fatal: could not read https://user:s3cret@github.com/a/b.git")

      refute redacted =~ "s3cret"
      assert redacted =~ "https://[REDACTED]@github.com/a/b.git"
    end

    test "leaves ordinary detail untouched" do
      assert Git.redact("agent exited with status 3") == "agent exited with status 3"
    end
  end

  describe "env_overrides/1" do
    test "unsets the askpass hooks a launching terminal injects" do
      env = Map.new(Git.env_overrides(nil))

      for key <- ~w(GIT_ASKPASS SSH_ASKPASS VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN
                    VSCODE_GIT_ASKPASS_EXTRA_ARGS VSCODE_GIT_IPC_HANDLE GIT_CONFIG_PARAMETERS) do
        assert Map.fetch!(env, key) == nil, "#{key} must be unset for git subprocesses"
      end
    end

    test "disables interactive prompting and pins the locale" do
      env = Map.new(Git.env_overrides(nil))

      assert env["GIT_TERMINAL_PROMPT"] == "0"
      assert env["GIT_SSH_COMMAND"] =~ "BatchMode=yes"
      assert env["LC_ALL"] == "C"
    end

    test "carries the token only when one is given" do
      assert Map.new(Git.env_overrides(nil))["CODELEAD_GIT_TOKEN"] == nil
      assert Map.new(Git.env_overrides("s3cret"))["CODELEAD_GIT_TOKEN"] == "s3cret"
    end
  end

  describe "credential_args/1" do
    test "installs no helper without a token" do
      assert Git.credential_args(nil) == []
    end

    test "resets inherited helpers before installing ours" do
      assert ["-c", "credential.helper=", "-c", "credential.helper=" <> _ours] =
               Git.credential_args("s3cret")
    end

    test "the helper answers a get with the token from the environment" do
      ["-c", _reset, "-c", "credential.helper=!" <> shell] = Git.credential_args("s3cret")

      # Git runs the `!`-prefixed helper through the shell with the
      # operation appended — same as here.
      {output, 0} =
        System.cmd("sh", ["-c", shell <> " get"],
          env: [{"CODELEAD_GIT_TOKEN", "s3cret"}],
          stderr_to_stdout: true
        )

      assert output =~ "username=x-access-token"
      assert output =~ "password=s3cret"
    end

    test "the helper stays silent for operations other than get" do
      ["-c", _reset, "-c", "credential.helper=!" <> shell] = Git.credential_args("s3cret")

      {output, _status} =
        System.cmd("sh", ["-c", shell <> " store"], env: [{"CODELEAD_GIT_TOKEN", "s3cret"}])

      refute output =~ "s3cret"
    end
  end

  describe "ensure_clone/3" do
    setup do
      root = Application.fetch_env!(:code_lead, :workspace_root)
      path = Path.join([root, "test_clones", "clone-#{System.unique_integer([:positive])}"])
      on_exit(fn -> File.rm_rf!(path) end)
      %{git_url: GitHelpers.create_origin!(), path: path}
    end

    test "clones with the credential overrides in place", %{git_url: git_url, path: path} do
      assert {:ok, ^path} = Git.ensure_clone(git_url, path, token: "unused-for-file-remotes")
      assert File.dir?(Path.join(path, ".git"))
    end

    test "fetches an existing clone instead of re-cloning", %{git_url: git_url, path: path} do
      assert {:ok, ^path} = Git.ensure_clone(git_url, path)
      GitHelpers.commit_on_origin!(git_url, "later.md", "later\n")

      assert {:ok, ^path} = Git.ensure_clone(git_url, path)
      assert {:ok, log} = Git.git(path, ["log", "--oneline", "origin/main"])
      assert log =~ "origin change"
    end

    test "re-points origin when the project's repository URL changed",
         %{git_url: git_url, path: path} do
      assert {:ok, ^path} = Git.ensure_clone(git_url, path)

      moved = GitHelpers.create_origin!()
      assert {:ok, ^path} = Git.ensure_clone(moved, path)

      assert {:ok, origin} = Git.git(path, ["remote", "get-url", "origin"])
      assert String.trim(origin) == moved
    end

    test "reports the git failure in English instead of prompting", %{path: path} do
      assert {:error, output} =
               Git.ensure_clone("file:///nonexistent/codelead-missing.git", path)

      # LC_ALL=C: the message must be matchable regardless of the host locale.
      assert output =~ "fatal:"
      assert output =~ "does not appear to be a git repository"
    end
  end

  describe "diff/2" do
    setup do
      root = Application.fetch_env!(:code_lead, :workspace_root)
      id = System.unique_integer([:positive])
      clone = Path.join([root, "test_clones", "diff-clone-#{id}"])
      worktree = Path.join([root, "test_clones", "diff-worktree-#{id}"])

      on_exit(fn ->
        File.rm_rf!(worktree)
        File.rm_rf!(clone)
      end)

      {:ok, _} = Git.ensure_clone(GitHelpers.create_origin!(), clone)
      {:ok, _} = Git.create_worktree(clone, worktree, "task/diff-#{id}", "main")

      %{worktree: worktree}
    end

    test "covers tracked edits and untracked files alike", %{worktree: worktree} do
      File.write!(Path.join(worktree, "README.md"), "# Changed\n")
      File.write!(Path.join(worktree, "new.md"), "brand new\n")

      assert {:ok, output} = Git.diff(worktree, "main")
      assert output =~ "README.md"
      assert output =~ "new.md"
      assert output =~ "brand new"
    end

    # The Diff tab polls this while an agent works in the same worktree.
    # Staging into the real index would fight the agent for index.lock and
    # could fail its commit.
    test "leaves the worktree index untouched", %{worktree: worktree} do
      File.write!(Path.join(worktree, "new.md"), "brand new\n")

      assert {:ok, _output} = Git.diff(worktree, "main")

      assert {:ok, staged} = Git.git(worktree, ["diff", "--cached", "--name-only"])
      assert String.trim(staged) == ""
    end

    test "is repeatable and cleans up its scratch index", %{worktree: worktree} do
      File.write!(Path.join(worktree, "new.md"), "brand new\n")

      assert {:ok, first} = Git.diff(worktree, "main")
      assert {:ok, ^first} = Git.diff(worktree, "main")

      assert Path.wildcard(Path.join(System.tmp_dir!(), "codelead-diff-*.index")) == []
    end
  end

  describe "check_access/2" do
    test "succeeds against a reachable remote without cloning it" do
      git_url = GitHelpers.create_origin!()

      assert Git.check_access(git_url, token: "unused-for-file-remotes") == :ok
    end

    test "reports why an unreachable remote refused" do
      assert {:error, output} = Git.check_access("file:///nonexistent/codelead-missing.git")
      assert output =~ "does not appear to be a git repository"
    end
  end
end
