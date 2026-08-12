defmodule CodeLead.GitTest do
  use ExUnit.Case, async: true

  alias CodeLead.Git
  alias CodeLead.GitHelpers

  # What GitHub answers a credential that can read the repository but has
  # no write scope: the push is refused with a 403 rather than a
  # credential challenge.
  @write_denied_output """
  remote: Write access to repository not granted.
  fatal: unable to access 'https://github.com/acme/assistant.git/': The requested URL returned error: 403
  """

  @forge {:github, "acme", "assistant"}

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

  describe "refusal/1" do
    test "separates a read-only credential from a rejected one" do
      assert Git.refusal(@write_denied_output) == :write_denied

      assert Git.refusal("remote: You are not allowed to push code to this project.\n") ==
               :write_denied
    end

    test "recognizes a rejected credential" do
      assert Git.refusal("remote: Invalid username or token.\n") == :auth
      assert Git.refusal("fatal: Authentication failed for 'https://github.com/a/b/'\n") == :auth
    end

    test "stays out of the way when the failure is not about credentials" do
      assert Git.refusal("fatal: '/nope.git' does not appear to be a git repository\n") == :other
    end
  end

  describe "remote_failure/4" do
    test "names the missing write scope when a token was presented" do
      message = Git.remote_failure("push the branch", @write_denied_output, @forge, true)

      assert message =~ "GITHUB_TOKEN in the project env store can read acme/assistant"
      assert message =~ "Contents: Read and write"
      assert message =~ "github.com"
      assert message =~ "remote: Write access to repository not granted."
      # A read-only token is valid, so the expiry advice would misdirect.
      refute message =~ "has not expired"
    end

    test "blames the ambient credentials when no token was stored" do
      message = Git.remote_failure("push the branch", @write_denied_output, @forge, false)

      assert message =~ "add a GITHUB_TOKEN with write access"
      refute message =~ "can read acme/assistant"
    end

    test "names GitLab's scope for a GitLab remote" do
      output = "remote: You are not allowed to push code to this project.\n"
      message = Git.remote_failure("push the branch", output, {:gitlab, "acme", "site"}, true)

      assert message =~ "GITLAB_TOKEN"
      assert message =~ "write_repository"
    end

    test "blames the stored token when it was rejected outright" do
      output = "remote: Invalid username or token.\n"
      message = Git.remote_failure("push the branch", output, @forge, true)

      assert message =~ "rejected by github.com"
      assert message =~ "has not expired"
      refute message =~ "Contents: Read and write"
    end

    test "asks for a token only when none was stored" do
      output = "remote: Repository not found.\n"
      message = Git.remote_failure("push the branch", output, @forge, false)

      assert message =~ "could not push the branch — add a GITHUB_TOKEN"
      refute message =~ "rejected by"
    end

    test "explains that a remote without a token convention used the server's credentials" do
      output = "remote: Invalid username or token.\n"
      message = Git.remote_failure("push the branch", output, :other, false)

      refute message =~ "GITHUB_TOKEN"
      assert message =~ "no token convention"
    end

    test "reports the git line verbatim when the failure is not about credentials" do
      output = "fatal: '/nope.git' does not appear to be a git repository\n"

      assert Git.remote_failure("push the branch", output, @forge, true) ==
               "could not push the branch: #{String.trim(output)}"
    end

    test "redacts a credential that leaked into the git output" do
      output =
        "remote: Write access to repository not granted (ghp_abcdefghijklmnopqrstuvwxyz012345).\n"

      message = Git.remote_failure("push the branch", output, @forge, true)

      refute message =~ "ghp_abcdefghij"
      assert message =~ "[REDACTED]"
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

  describe "create_detached_worktree/3" do
    setup do
      root = Application.fetch_env!(:code_lead, :workspace_root)
      id = System.unique_integer([:positive])
      clone = Path.join([root, "test_clones", "survey-clone-#{id}"])
      worktree = Path.join([root, "test_clones", "survey-worktree-#{id}"])
      on_exit(fn -> Enum.each([clone, worktree], &File.rm_rf!/1) end)

      git_url = GitHelpers.create_origin!()
      {:ok, _} = Git.ensure_clone(git_url, clone)

      %{git_url: git_url, clone: clone, worktree: worktree}
    end

    test "checks out the default branch with no branch created",
         %{clone: clone, worktree: worktree} do
      assert {:ok, ^worktree} = Git.create_detached_worktree(clone, worktree, "main")
      assert File.exists?(Path.join(worktree, "README.md"))

      # A detached HEAD has no symbolic ref, so git exits non-zero.
      assert {:error, _output} = Git.git(worktree, ["symbolic-ref", "--quiet", "HEAD"])

      # Nothing but the clone's own `main` — the survey adds no branch.
      assert {:ok, branches} = Git.git(clone, ["branch", "--list"])
      assert branches |> String.split("\n", trim: true) |> length() == 1
    end

    test "reads current origin source, not the base clone's frozen checkout",
         %{git_url: git_url, clone: clone, worktree: worktree} do
      GitHelpers.commit_on_origin!(git_url, "fresh.md", "fresh\n")
      {:ok, _} = Git.ensure_clone(git_url, clone)

      # `ensure_clone/3` only fetches, so the clone's own checkout is
      # still at the first commit — the worktree is what sees the new file.
      refute File.exists?(Path.join(clone, "fresh.md"))

      assert {:ok, ^worktree} = Git.create_detached_worktree(clone, worktree, "main")
      assert File.exists?(Path.join(worktree, "fresh.md"))
    end

    test "remove_worktree/2 cleans it up", %{clone: clone, worktree: worktree} do
      {:ok, _} = Git.create_detached_worktree(clone, worktree, "main")
      assert :ok = Git.remove_worktree(clone, worktree)

      refute File.dir?(worktree)
      assert {:ok, list} = Git.git(clone, ["worktree", "list", "--porcelain"])
      refute list =~ worktree
    end
  end

  describe "merge/3 and push_ref/4" do
    setup do
      root = Application.fetch_env!(:code_lead, :workspace_root)
      id = System.unique_integer([:positive])
      clone = Path.join([root, "test_clones", "merge-clone-#{id}"])
      feature = Path.join([root, "test_clones", "merge-feature-#{id}"])
      staging = Path.join([root, "test_clones", "merge-staging-#{id}"])
      on_exit(fn -> Enum.each([clone, feature, staging], &File.rm_rf!/1) end)

      git_url = GitHelpers.create_origin!()
      {:ok, _} = Git.ensure_clone(git_url, clone)
      {:ok, _} = Git.create_worktree(clone, feature, "codelead/task-1", "main")

      %{
        git_url: git_url,
        clone: clone,
        feature: feature,
        staging: staging,
        branch: "codelead/task-1"
      }
    end

    test "merge/3 brings the branch's work in as a merge commit",
         %{clone: clone, feature: feature, staging: staging, branch: branch} do
      File.write!(Path.join(feature, "pricing.html"), "<h1>Pricing</h1>\n")
      {:ok, _} = Git.commit_all(feature, "add pricing")

      {:ok, _} = Git.create_detached_worktree(clone, staging, "main")

      assert {:ok, _output} =
               Git.merge(staging, branch, strategy: :merge, message: "merge task 1")

      assert File.exists?(Path.join(staging, "pricing.html"))
      assert {:ok, merges} = Git.git(staging, ["log", "--merges", "--oneline"])
      assert merges =~ "merge task 1"
    end

    test "merge/3 squashes the branch into a single commit",
         %{clone: clone, feature: feature, staging: staging, branch: branch} do
      File.write!(Path.join(feature, "a.md"), "a\n")
      {:ok, _} = Git.commit_all(feature, "first")
      File.write!(Path.join(feature, "b.md"), "b\n")
      {:ok, _} = Git.commit_all(feature, "second")

      {:ok, _} = Git.create_detached_worktree(clone, staging, "main")

      assert {:ok, _output} =
               Git.merge(staging, branch, strategy: :squash, message: "squash task 1")

      assert File.exists?(Path.join(staging, "a.md"))
      assert File.exists?(Path.join(staging, "b.md"))
      assert {:ok, log} = Git.git(staging, ["log", "--oneline"])
      # The squash adds exactly one commit on top of the seed commit.
      assert log |> String.split("\n", trim: true) |> length() == 2
      assert log =~ "squash task 1"
    end

    test "merge/3 is a noop when the branch adds nothing",
         %{clone: clone, staging: staging, branch: branch} do
      {:ok, _} = Git.create_detached_worktree(clone, staging, "main")

      assert Git.merge(staging, branch, strategy: :merge) == :noop
      assert Git.merge(staging, branch, strategy: :squash) == :noop
    end

    test "merge/3 reports a conflict rather than half-merging",
         %{git_url: git_url, clone: clone, feature: feature, staging: staging, branch: branch} do
      File.write!(Path.join(feature, "README.md"), "# Branch\n")
      {:ok, _} = Git.commit_all(feature, "branch edit")

      GitHelpers.commit_on_origin!(git_url, "README.md", "# Origin\n")
      {:ok, _} = Git.fetch(clone)
      {:ok, _} = Git.create_detached_worktree(clone, staging, "main")

      assert {:error, output} = Git.merge(staging, branch, strategy: :merge)
      assert Git.merge_refusal(output) == :conflict
    end

    test "push_ref/4 moves the remote default branch",
         %{git_url: git_url, clone: clone, feature: feature, staging: staging, branch: branch} do
      File.write!(Path.join(feature, "shipped.md"), "shipped\n")
      {:ok, _} = Git.commit_all(feature, "ship it")

      {:ok, _} = Git.create_detached_worktree(clone, staging, "main")
      {:ok, _} = Git.merge(staging, branch, strategy: :squash, message: "ship")
      assert {:ok, _output} = Git.push_ref(staging, "HEAD", "main")

      probe =
        Path.join([
          Application.fetch_env!(:code_lead, :workspace_root),
          "test_clones",
          "probe-#{System.unique_integer([:positive])}"
        ])

      on_exit(fn -> File.rm_rf!(probe) end)
      {:ok, _} = Git.ensure_clone(git_url, probe)
      assert File.exists?(Path.join(probe, "shipped.md"))
    end

    test "push_ref/4 refuses to overwrite a default branch that moved",
         %{git_url: git_url, clone: clone, feature: feature, staging: staging, branch: branch} do
      File.write!(Path.join(feature, "ours.md"), "ours\n")
      {:ok, _} = Git.commit_all(feature, "ours")

      {:ok, _} = Git.create_detached_worktree(clone, staging, "main")
      {:ok, _} = Git.merge(staging, branch, strategy: :merge, message: "merge ours")

      # Someone else pushes to main between the merge and our push.
      GitHelpers.commit_on_origin!(git_url, "theirs.md", "theirs\n")

      assert {:error, output} = Git.push_ref(staging, "HEAD", "main")
      assert Git.merge_refusal(output) == :non_fast_forward
    end

    test "delete_remote_branch/3 removes the feature branch from the remote",
         %{clone: clone, feature: feature, branch: branch} do
      File.write!(Path.join(feature, "x.md"), "x\n")
      {:ok, _} = Git.commit_all(feature, "x")
      {:ok, _} = Git.push(feature, branch)
      assert {:ok, branches} = Git.remote_branches(clone)
      assert branch in branches

      assert {:ok, _output} = Git.delete_remote_branch(clone, branch)
      assert {:ok, remaining} = Git.remote_branches(clone)
      refute branch in remaining
    end

    test "head_sha/1 names the commit a merge produced",
         %{clone: clone, feature: feature, staging: staging, branch: branch} do
      File.write!(Path.join(feature, "y.md"), "y\n")
      {:ok, _} = Git.commit_all(feature, "y")

      {:ok, _} = Git.create_detached_worktree(clone, staging, "main")
      {:ok, _} = Git.merge(staging, branch, strategy: :squash, message: "y")

      assert {:ok, sha} = Git.head_sha(staging)
      assert String.match?(sha, ~r/^[0-9a-f]{40}$/)
    end
  end

  describe "merge_refusal/1 and merge_failure/4" do
    test "classifies by what the operator has to change" do
      assert Git.merge_refusal("CONFLICT (content): Merge conflict in README.md") == :conflict

      assert Git.merge_refusal("! [rejected]  HEAD -> main (non-fast-forward)") ==
               :non_fast_forward

      assert Git.merge_refusal("remote: GH006: Protected branch update failed") == :protected
      assert Git.merge_refusal(@write_denied_output) == :other
    end

    test "names the remedy per class" do
      conflict =
        Git.merge_failure("main", "CONFLICT (content): Merge conflict in a.md", @forge, true)

      assert conflict =~ "conflicts with main"
      assert conflict =~ "Pull request"

      stale =
        Git.merge_failure("main", "error: failed to push\nhint: non-fast-forward", @forge, true)

      assert stale =~ "moved on the remote"
      assert stale =~ "approve again"

      protected =
        Git.merge_failure("main", "remote: GH006: Protected branch update failed", @forge, true)

      assert protected =~ "protected"
      assert protected =~ "Pull request"
    end

    test "delegates a credential problem to remote_failure/4" do
      # A read-only token is a credential problem, not a merge problem —
      # the remedy is the scope, so none of the merge wording applies.
      assert Git.merge_failure("main", @write_denied_output, @forge, true) =~
               "GITHUB_TOKEN in the project env store can read acme/assistant"

      # An uncategorized failure still names what was attempted.
      assert Git.merge_failure("main", "fatal: not a git repository\n", @forge, true) ==
               "could not merge into main: fatal: not a git repository"
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
