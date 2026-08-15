defmodule CodeLeadWeb.FormatTest do
  use ExUnit.Case, async: true

  alias CodeLeadWeb.Format

  describe "duration/1" do
    test "nothing to show" do
      assert Format.duration(nil) == "—"
      assert Format.duration(-1) == "—"
    end

    # Rows predating duration tracking sum to 0; that is unknown, not
    # instant, and must not render as a confident "0ms".
    test "zero reads as unknown" do
      assert Format.duration(0) == "—"
    end

    test "sub-second runs keep their milliseconds" do
      assert Format.duration(1) == "1ms"
      assert Format.duration(820) == "820ms"
    end

    test "seconds, minutes and hours" do
      assert Format.duration(1_000) == "1.0s"
      assert Format.duration(59_900) == "59.9s"
      assert Format.duration(134_000) == "2m 14s"
      assert Format.duration(3_600_000) == "1h 00m"
      assert Format.duration(3_840_000) == "1h 04m"
    end
  end

  describe "cost/2" do
    test "exact money is plain" do
      assert Format.cost(42, :exact) == "$0.42"
      assert Format.cost(nil, :exact) == "$0.00"
    end

    test "a subscription run is marked as an estimate" do
      assert Format.cost(42, :estimated) == "~$0.42 est"
    end

    test "a local model shows no money at all" do
      assert Format.cost(42, :free) == "—"
    end
  end

  describe "absolute/1" do
    test "nothing to show" do
      assert Format.absolute(nil) == "—"
    end

    test "spells out the date, time and zone" do
      at = ~U[2026-08-11 14:31:02Z]
      assert Format.absolute(at) == "Aug 11, 2026 · 14:31 UTC"
    end

    test "a naive timestamp is read as UTC" do
      assert Format.absolute(~N[2026-08-11 14:31:02]) == Format.absolute(~U[2026-08-11 14:31:02Z])
    end
  end

  describe "iso8601/1" do
    test "nothing to show leaves the attribute empty" do
      assert Format.iso8601(nil) == nil
    end

    test "renders a machine-readable timestamp" do
      assert Format.iso8601(~U[2026-08-11 14:31:02Z]) == "2026-08-11T14:31:02Z"
      assert Format.iso8601(~N[2026-08-11 14:31:02]) == "2026-08-11T14:31:02Z"
    end
  end

  describe "reset_in/1" do
    test "nothing to show" do
      assert Format.reset_in(nil) == "—"
    end

    test "already reset" do
      assert Format.reset_in(DateTime.add(DateTime.utc_now(), -5, :minute)) == "now"
    end

    test "resets within the hour" do
      at = DateTime.add(DateTime.utc_now(), 31 * 60 + 5, :second)
      assert Format.reset_in(at) == "31m"
    end

    test "resets later today" do
      at = DateTime.add(DateTime.utc_now(), 2 * 3_600 + 31 * 60 + 5, :second)
      assert Format.reset_in(at) == "2h 31m"
    end

    test "resets beyond a day shows the weekday and clock time" do
      at = DateTime.add(DateTime.utc_now(), 2, :day)
      assert Format.reset_in(at) == Calendar.strftime(at, "%a %H:%M")
    end
  end

  describe "run_stat/4" do
    test "joins the segments it has" do
      assert Format.run_stat(207, 183_512, 134_000) == "$2.07 · 183.5k · 2m 14s"
    end

    test "drops segments with nothing to say rather than printing dashes" do
      assert Format.run_stat(207, 183_512, nil, :free) == "183.5k"
      assert Format.run_stat(207, 0, 134_000, :free) == "2m 14s"
    end

    test "an entirely empty stat collapses to one dash" do
      assert Format.run_stat(nil, nil, nil, :free) == "—"
    end
  end

  describe "finalize_action/2" do
    test "states the mode the finalizer will actually run" do
      assert Format.finalize_action(:pull_request, true) == "Approve & open PR"
      assert Format.finalize_action(:merge, true) == "Approve & merge"
      assert Format.finalize_action(:squash, true) == "Approve & squash merge"
      assert Format.finalize_action(:artifact, false) == "Approve & hand over"
      assert Format.finalize_action(:commit_to_path, false) == "Approve & commit artifact"
    end

    test "promises only a push when the remote has no forge convention" do
      assert Format.finalize_action(:pull_request, false) == "Approve & push branch"
    end
  end

  describe "finalize_hint/2" do
    test "names the branch a merge writes to" do
      assert Format.finalize_hint(:merge, "trunk") =~ "merges it into trunk"
      assert Format.finalize_hint(:squash, "trunk") =~ "lands it on trunk"
    end

    test "falls back when no repository is linked" do
      assert Format.finalize_hint(:merge, nil) =~ "the default branch"
    end

    test "says nothing is pushed for a folder artifact" do
      assert Format.finalize_hint(:artifact, nil) =~ "Nothing is pushed"
    end
  end

  describe "forge_link/1" do
    test "labels each link kind" do
      assert Format.forge_link(:pull_request) == "PR"
      assert Format.forge_link(:merge_request) == "MR"
      assert Format.forge_link(:commit) == "Commit"
      assert Format.forge_link(:compare) == "Compare"
      assert Format.forge_link(nil) == "Compare"
    end
  end

  describe "project_path/2" do
    test "a path inside the root loses the prefix" do
      assert Format.project_path("/w/worktrees/task-5/docs/x.md", "/w/worktrees/task-5") ==
               "docs/x.md"
    end

    test "an already-relative path is left alone" do
      assert Format.project_path("lib/foo.ex", "/w/worktrees/task-5") == "lib/foo.ex"
    end

    test "the root itself is the current directory" do
      assert Format.project_path("/w/worktrees/task-5", "/w/worktrees/task-5") == "."
    end

    test "a path outside the root has no project-relative form" do
      assert Format.project_path("/etc/passwd", "/w/worktrees/task-5") == nil
      assert Format.project_path("/w/worktrees/task-50/x.md", "/w/worktrees/task-5") == nil
    end

    test "no root means nothing to relativize against" do
      assert Format.project_path("/etc/passwd", nil) == nil
    end
  end
end
