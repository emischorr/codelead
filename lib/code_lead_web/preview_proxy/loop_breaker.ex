defmodule CodeLeadWeb.PreviewProxy.LoopBreaker do
  @moduledoc """
  Breaks the reload loop a previewed app falls into when it emits
  root-absolute URLs that escape its `/preview/<task_id>` mount.

  The pathology, as observed: an app honoring `PREVIEW_BASE_PATH` still
  ships paths that its router config cannot reach — a hardcoded
  `new LiveSocket("/live", …)` in the JS bundle above all. That socket
  opens against *CodeLead's* LiveView endpoint, which completes the
  upgrade and then rejects the join (the session token was signed by
  another app's `secret_key_base`). The client reads that as `stale`,
  falls back to a full page request, and the whole cycle repeats a
  couple of times a second until something upstream rate-limits it.

  Counting is keyed by an opaque term the caller chooses and scoped to
  one path: this counts *the same page reloading itself*, never a user
  moving around a working preview.

  State is a plain map in this process rather than an ETS table. Only
  top-level document navigations are recorded — a handful per second at
  the very worst — so the serialization point cannot matter. Should the
  guard ever widen to subresources, ETS becomes the right call.

  Never blocks a preview: a breaker that is down, slow, or disabled
  answers `:ok`, so a fault here can only fail *open*.

  ## Why the websocket itself is not the detector

  Tempting, since the escaped handshake is the true first symptom — but
  under the path gateway it is indistinguishable from CodeLead's own:
  same host, same origin, CodeLead's own cookies (the preview's are
  path-scoped to `/preview/<id>` and so not sent), and no `Referer` at
  all, since browsers send none on a websocket handshake. The one real
  discriminator is the `_csrf_token`'s signature, which requires
  replacing `Phoenix.LiveView.Socket` on the endpoint's `/live` line —
  the transport the entire product rides — and it *also* fires on
  CodeLead's own tabs after a session rotation, where the reload is the
  correct self-heal. Log-only would misreport those; rejecting would
  break them. The document navigations counted here are 100% of the
  loop anyway, and are the only signal that can be explained to a user.
  """

  use GenServer

  @threshold 5
  @window_ms 10_000
  @pause_ms 5 * 60_000
  @sweep_ms 60_000
  @max_entries 10_000

  @typedoc "Opaque per-client counter key; the caller decides its shape."
  @type key :: term()
  @type verdict :: :ok | :tripped

  @doc """
  Starts the breaker. Besides `:name`, accepts `:threshold`,
  `:window_ms`, `:pause_ms` and `:sweep_ms` — resolved once at init so
  tests can drive an isolated instance without touching app config.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records one top-level navigation to `path` for `key` and reports
  whether it completes a reload loop. A trip clears the entry, so the
  count starts clean rather than latching.
  """
  @spec record(key(), String.t(), GenServer.server()) :: verdict()
  def record(key, path, server \\ __MODULE__) do
    GenServer.call(server, {:record, key, path}, 1_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Suppresses trips for `key` — what the interstitial's load-it-anyway link calls."
  @spec pause(key(), GenServer.server()) :: :ok
  def pause(key, server \\ __MODULE__) do
    GenServer.call(server, {:pause, key}, 1_000)
  catch
    :exit, _ -> :ok
  end

  @doc "Whether the breaker is armed instance-wide (`PREVIEW_LOOP_BREAKER=off` disarms it)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:code_lead, :preview_loop_breaker, true) != false

  @impl true
  def init(opts) do
    state = %{
      entries: %{},
      threshold: Keyword.get(opts, :threshold, @threshold),
      window_ms: Keyword.get(opts, :window_ms, @window_ms),
      pause_ms: Keyword.get(opts, :pause_ms, @pause_ms),
      sweep_ms: Keyword.get(opts, :sweep_ms, @sweep_ms)
    }

    Process.send_after(self(), :sweep, state.sweep_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:record, key, path}, _from, state) do
    now = now_ms()

    case advance(Map.get(state.entries, key), path, now, state) do
      :tripped -> {:reply, :tripped, drop(state, key)}
      entry -> {:reply, :ok, put(state, key, entry)}
    end
  end

  def handle_call({:pause, key}, _from, state) do
    now = now_ms()
    entry = Map.get(state.entries, key, fresh("", now))
    {:reply, :ok, put(state, key, %{entry | paused_until: now + state.pause_ms, last_at: now})}
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, state.sweep_ms)
    {:noreply, %{state | entries: sweep(state.entries, now_ms(), state.window_ms)}}
  end

  # A paused key keeps its liveness but can never trip; a new path, an
  # expired window, or no entry at all starts over at one.
  defp advance(%{paused_until: until} = entry, _path, now, _state)
       when is_integer(until) and until > now,
       do: %{entry | last_at: now}

  defp advance(nil, path, now, _state), do: fresh(path, now)

  defp advance(%{path: stored}, path, now, _state) when stored != path, do: fresh(path, now)

  defp advance(%{first_at: first_at}, path, now, %{window_ms: window_ms})
       when now - first_at > window_ms,
       do: fresh(path, now)

  defp advance(%{count: count}, _path, _now, %{threshold: threshold})
       when count + 1 >= threshold,
       do: :tripped

  defp advance(entry, _path, now, _state),
    do: %{entry | count: entry.count + 1, last_at: now}

  defp fresh(path, now),
    do: %{path: path, count: 1, first_at: now, last_at: now, paused_until: nil}

  defp put(state, key, entry),
    do: %{state | entries: state.entries |> Map.put(key, entry) |> cap()}

  defp drop(state, key), do: %{state | entries: Map.delete(state.entries, key)}

  # Bounds memory between sweeps: whatever the task, session or malice
  # count, the table stays a fixed size.
  defp cap(entries) when map_size(entries) <= @max_entries, do: entries

  defp cap(entries) do
    entries
    |> Enum.sort_by(fn {_key, %{last_at: last_at}} -> last_at end, :desc)
    |> Enum.take(@max_entries)
    |> Map.new()
  end

  defp sweep(entries, now, window_ms) do
    Map.reject(entries, fn {_key, %{last_at: last_at, paused_until: until}} ->
      now - last_at > window_ms and (is_nil(until) or until <= now)
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
