defmodule CodeLead.Runtime.TaskRunnerTest do
  use ExUnit.Case, async: true

  alias CodeLead.Runtime.TaskRunner

  describe "dispatch_error/1" do
    test "names a missing harness binary and what to do" do
      message = TaskRunner.dispatch_error({:executable_not_found, "claude-agent-acp"})

      assert message =~ "claude-agent-acp"
      assert message =~ "not found on PATH"
    end

    test "names an unconfigured harness" do
      assert TaskRunner.dispatch_error({:unknown_harness, :codex}) =~ ":codex"
    end

    test "points a git auth failure at the project env store" do
      output = """
      Cloning into '/workspace/repos/assistant-1'...
      remote: Repository not found.
      fatal: Authentication failed for 'https://github.com/acme/assistant/'
      """

      message = TaskRunner.dispatch_error({:provision, output})

      assert message =~ "GITHUB_TOKEN"
      assert message =~ "remote: Repository not found."
    end

    test "surfaces the meaningful git line for other provisioning failures" do
      output = """
      Cloning into '/workspace/repos/assistant-1'...
      fatal: '/nope.git' does not appear to be a git repository
      """

      message = TaskRunner.dispatch_error({:provision, output})

      refute message =~ "GITHUB_TOKEN"
      assert message =~ "does not appear to be a git repository"
    end

    test "names the blocked path and the host-side remedy for a stuck leftover" do
      message =
        TaskRunner.dispatch_error({:provision, {:workspace_blocked, "/data/worktrees/task-7"}})

      assert message =~ "/data/worktrees/task-7"
      assert message =~ "remove that directory on the host"
    end

    test "falls back to inspect for unrecognized reasons" do
      assert TaskRunner.dispatch_error(:invalid_state) == ":invalid_state"
    end
  end

  describe "dispatch_error/1 with a remote failure" do
    @auth_output """
    Cloning into '/workspace/repos/assistant-1'...
    remote: Invalid username or token. Password authentication is not supported.
    fatal: Authentication failed for 'https://github.com/acme/assistant/'
    """

    test "blames the stored token when one was presented" do
      message = remote_error(@auth_output, {:github, "acme", "assistant"}, true)

      assert message =~ "GITHUB_TOKEN in the project env store was rejected by github.com"
      assert message =~ "acme/assistant"
      assert message =~ "remote: Invalid username or token."
      refute message =~ "add a GITHUB_TOKEN"
    end

    test "asks for a token only when none was stored" do
      message = remote_error(@auth_output, {:gitlab, "acme", "assistant"}, false)

      assert message =~ "add a GITLAB_TOKEN to the project env store"
      refute message =~ "rejected by"
    end

    test "explains that a remote without a token convention used the server's credentials" do
      message = remote_error(@auth_output, :other, false)

      refute message =~ "GITHUB_TOKEN"
      assert message =~ "no token convention"
      assert message =~ "server's own git credentials"
    end

    test "stays out of the way when the failure is not about auth" do
      output = "fatal: '/nope.git' does not appear to be a git repository\n"
      message = remote_error(output, {:github, "acme", "assistant"}, true)

      assert message == "could not prepare the workspace: #{String.trim(output)}"
    end
  end

  defp remote_error(output, forge, token_present?) do
    TaskRunner.dispatch_error(
      {:provision, {:remote, %{output: output, forge: forge, token_present?: token_present?}}}
    )
  end
end
