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
end
