defmodule CodeLeadWeb.PreviewProxy.LoopBreakerTest do
  use ExUnit.Case, async: true

  alias CodeLeadWeb.PreviewProxy.LoopBreaker

  # Every test drives its own instance with its own knobs, so nothing
  # touches the supervised singleton or app config.
  setup context do
    name = :"breaker_#{:erlang.phash2(context.test)}"

    pid =
      start_supervised!(
        {LoopBreaker, name: name, threshold: 3, window_ms: 60, pause_ms: 60, sweep_ms: 20},
        id: name
      )

    %{breaker: name, pid: pid}
  end

  describe "record/3" do
    test "trips on the Nth navigation to the same path", %{breaker: b} do
      assert :ok == LoopBreaker.record(:k, "/preview/1/", b)
      assert :ok == LoopBreaker.record(:k, "/preview/1/", b)
      assert :tripped == LoopBreaker.record(:k, "/preview/1/", b)
    end

    test "a different path resets the count", %{breaker: b} do
      for path <- ["/a", "/b", "/a", "/b", "/a", "/b"] do
        assert :ok == LoopBreaker.record(:k, path, b)
      end
    end

    test "a gap longer than the window resets the count", %{breaker: b} do
      assert :ok == LoopBreaker.record(:k, "/a", b)
      assert :ok == LoopBreaker.record(:k, "/a", b)
      Process.sleep(80)
      assert :ok == LoopBreaker.record(:k, "/a", b)
      assert :ok == LoopBreaker.record(:k, "/a", b)
    end

    test "a trip clears the entry rather than latching", %{breaker: b} do
      LoopBreaker.record(:k, "/a", b)
      LoopBreaker.record(:k, "/a", b)
      assert :tripped == LoopBreaker.record(:k, "/a", b)
      assert :ok == LoopBreaker.record(:k, "/a", b)
    end

    test "distinct keys do not interfere", %{breaker: b} do
      LoopBreaker.record(:one, "/a", b)
      LoopBreaker.record(:one, "/a", b)
      assert :ok == LoopBreaker.record(:two, "/a", b)
      assert :tripped == LoopBreaker.record(:one, "/a", b)
    end

    test "fails open when the breaker is down" do
      assert :ok == LoopBreaker.record(:k, "/a", :no_such_breaker)
    end
  end

  describe "pause/2" do
    test "suppresses trips, and they resume afterwards", %{breaker: b} do
      :ok = LoopBreaker.pause(:k, b)

      for _ <- 1..10, do: assert(:ok == LoopBreaker.record(:k, "/a", b))

      Process.sleep(80)

      LoopBreaker.record(:k, "/a", b)
      LoopBreaker.record(:k, "/a", b)
      assert :tripped == LoopBreaker.record(:k, "/a", b)
    end
  end

  describe "housekeeping" do
    test "the sweep drops entries idle beyond the window", %{breaker: b, pid: pid} do
      LoopBreaker.record(:k, "/a", b)
      assert map_size(:sys.get_state(pid).entries) == 1

      Process.sleep(120)

      assert map_size(:sys.get_state(pid).entries) == 0
    end

    test "keeps the newest entries when the cap is exceeded", %{breaker: b, pid: pid} do
      for i <- 1..10_100, do: LoopBreaker.record({:key, i}, "/a", b)

      entries = :sys.get_state(pid).entries

      assert map_size(entries) <= 10_000
      assert Map.has_key?(entries, {:key, 10_100})
    end
  end
end
