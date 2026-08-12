defmodule CodeLeadWeb.FlashMessagesTest do
  use ExUnit.Case, async: true

  alias CodeLeadWeb.FlashMessages

  describe "finalize_error/1" do
    test "explains a read-only token instead of dumping git output" do
      output = """
      remote: Write access to repository not granted.
      fatal: unable to access 'https://github.com/acme/assistant.git/': The requested URL returned error: 403
      """

      message =
        FlashMessages.finalize_error(
          {:push_failed,
           {:remote,
            %{output: output, forge: {:github, "acme", "assistant"}, token_present?: true}}}
        )

      assert message =~ "GITHUB_TOKEN"
      assert message =~ "Contents: Read and write"
      # The raw error shape must never reach the operator.
      refute message =~ "{:push_failed"
      refute message =~ "%{"
    end

    test "names what to do about a missing worktree, branch, or checkout" do
      assert FlashMessages.finalize_error({:push_failed, :no_worktree}) =~ "no worktree"
      assert FlashMessages.finalize_error({:push_failed, :no_branch}) =~ "no feature branch"
      assert FlashMessages.finalize_error({:push_failed, :worktree_missing}) =~ "gone from disk"

      for reason <- [:no_worktree, :no_branch, :worktree_missing] do
        assert FlashMessages.finalize_error({:push_failed, reason}) =~ "Send it back to Planning"
      end
    end

    test "explains an empty task folder" do
      assert FlashMessages.finalize_error(:no_artifact) =~ "no artifact"
    end

    test "names the remedy for a merge that could not land" do
      message =
        FlashMessages.finalize_error(
          {:merge_failed,
           {:remote,
            %{
              output: "CONFLICT (content): Merge conflict in README.md",
              forge: {:github, "acme", "assistant"},
              token_present?: true,
              base_branch: "main"
            }}}
        )

      assert message =~ "conflicts with main"
      assert message =~ "Pull request"
      refute message =~ "{:merge_failed"
    end

    test "a merge that failed before merging reuses the push wording" do
      # A merge pushes the feature branch first, so the same atoms reach it.
      assert FlashMessages.finalize_error({:merge_failed, :worktree_missing}) ==
               FlashMessages.finalize_error({:push_failed, :worktree_missing})
    end

    test "explains commit-to-path with no repository linked" do
      message = FlashMessages.finalize_error(:no_artifact_repository)

      assert message =~ "none is linked"
      assert message =~ "Artifact"
    end

    test "delegates an unavailable action to the transition wording" do
      assert FlashMessages.finalize_error(:invalid_state) ==
               FlashMessages.transition_error(:invalid_state)
    end

    test "falls back to inspect for unrecognized reasons" do
      assert FlashMessages.finalize_error(:boom) == "Finalization failed: :boom"
    end
  end
end
