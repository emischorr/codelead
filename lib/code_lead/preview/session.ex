defmodule CodeLead.Preview.Session do
  @moduledoc """
  One preview server per task: owns the Port (so a page refresh kills
  only the LiveView, never the server), keeps a bounded log for the
  failure panel, probes the preview upstream until the port answers,
  and broadcasts lifecycle changes on the task topic. Stops itself when
  the server exits, when the start timeout passes without readiness, or
  after sitting viewer-less past the idle timeout; `restart: :temporary`
  — a stopped preview is restarted by the UI on demand, not by the
  supervisor.

  Traps exits so that *every* way out runs the stopper — an application
  shutdown included. Closing the Port would leave the server running
  (ADR-0013), so the signal is the only thing that ends it.
  """

  use GenServer, restart: :temporary, shutdown: 10_000

  alias CodeLead.Preview

  @log_limit 64_000
  @probe_interval_ms 1_000

  @typedoc """
  `port_opener: nil` starts an **adopted** session: the server predates
  this VM — it survived an ungraceful exit inside its container — and is
  reachable only through `stopper`. Such a session owns no Port, so it
  learns nothing from stdout and nothing from an exit; the probe is its
  only liveness signal, which is why it still starts in `:starting`.
  """
  @type start_arg :: %{
          task_id: pos_integer(),
          port_opener: (-> port()) | nil,
          stopper: (pos_integer() | nil -> :ok),
          probe: (-> :ready | :waiting)
        }

  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link(%{task_id: task_id} = arg) do
    GenServer.start_link(__MODULE__, arg, name: Preview.via(task_id))
  end

  @impl true
  def init(%{task_id: task_id, port_opener: port_opener, stopper: stopper, probe: probe}) do
    Process.flag(:trap_exit, true)
    port = if port_opener, do: port_opener.()
    Preview.broadcast(task_id, :starting)
    # After the port opens, never before: `terminate/2` does not run if
    # `init/1` raises, and this is the only thing here that can — an
    # earlier announcement would leave an open with no matching close.
    Preview.broadcast_session(task_id, :opened)
    Process.send_after(self(), :probe, @probe_interval_ms)
    start_timer = Process.send_after(self(), :start_timeout, Preview.start_timeout_ms())

    {:ok,
     %{
       task_id: task_id,
       port: port,
       # Resolved now, not at stop time: a port that has already exited
       # reports no os pid, and the group it led may still hold members
       # — precisely the background children a stop has to reap.
       os_pid: os_pid(port),
       stopper: stopper,
       probe: probe,
       status: :starting,
       log: <<>>,
       viewers: %{},
       idle_timer: schedule_idle(),
       start_timer: start_timer
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:stop, _from, state) do
    state = stop_server(state)
    Preview.broadcast(state.task_id, :stopped)
    {:stop, :normal, :ok, state}
  end

  def handle_call({:attach, viewer}, _from, state) do
    ref = Process.monitor(viewer)
    state = %{state | viewers: Map.put(state.viewers, ref, viewer)}
    {:reply, :ok, cancel_idle(state)}
  end

  def handle_call({:detach, viewer}, _from, state) do
    {:reply, :ok, drop_viewer(state, viewer)}
  end

  @impl true
  def handle_info(:probe, %{status: :starting} = state) do
    case state.probe.() do
      :ready ->
        Process.cancel_timer(state.start_timer)
        Preview.broadcast(state.task_id, :ready)
        {:noreply, %{state | status: :ready, start_timer: nil}}

      :waiting ->
        Process.send_after(self(), :probe, @probe_interval_ms)
        {:noreply, state}
    end
  end

  def handle_info(:probe, state), do: {:noreply, state}

  # An adopted session has no log to show, so a timeout is not a failure
  # panel — it is the reconciliation: the recorded pid is not serving,
  # so signal it and forget it.
  def handle_info(:start_timeout, %{status: :starting, port: nil} = state) do
    state = stop_server(state)
    Preview.broadcast(state.task_id, :stopped)
    {:stop, :normal, state}
  end

  def handle_info(:start_timeout, %{status: :starting} = state) do
    state = stop_server(state)
    Preview.broadcast(state.task_id, {:failed, state.log})
    {:stop, :normal, state}
  end

  def handle_info(:start_timeout, state), do: {:noreply, state}

  def handle_info({port, {:data, chunk}}, %{port: port} = state) when is_port(port) do
    {:noreply, %{state | log: append_log(state.log, chunk)}}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port, status: :starting} = state)
      when is_port(port) do
    Preview.broadcast(state.task_id, {:failed, state.log})
    {:stop, :normal, state}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) when is_port(port) do
    Preview.broadcast(state.task_id, :stopped)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.viewers, ref) do
      {nil, _viewers} -> {:noreply, state}
      {_pid, viewers} -> {:noreply, maybe_idle(%{state | viewers: viewers})}
    end
  end

  def handle_info(:idle_timeout, %{viewers: viewers} = state) when map_size(viewers) == 0 do
    state = stop_server(state)
    Preview.broadcast(state.task_id, :stopped)
    {:stop, :normal, state}
  end

  def handle_info(:idle_timeout, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Ahead of the stopper: a container stopper waits up to 5s on a
    # `docker exec`, and the readout should not lag the decision.
    Preview.broadcast_session(state.task_id, :closed)
    state |> stop_server() |> close_port()
  end

  # The server process outlives its Port (docker exec's death never
  # reaches into the container; a shell's children survive an EOF), so
  # stopping means signalling it explicitly. Clearing the stopper is what
  # makes this safe to call from every exit path, `terminate/2` included.
  defp stop_server(%{stopper: nil} = state), do: state

  defp stop_server(%{stopper: stopper, os_pid: os_pid} = state) do
    stopper.(os_pid)
    %{state | stopper: nil}
  rescue
    _cannot_signal -> %{state | stopper: nil}
  end

  defp os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp os_pid(_no_port), do: nil

  defp close_port(%{port: port} = _state) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  catch
    # The port can die between the info check and the close.
    :error, :badarg -> :ok
  end

  defp close_port(_no_port), do: :ok

  defp drop_viewer(state, viewer) do
    {gone, viewers} =
      Enum.split_with(state.viewers, fn {_ref, pid} -> pid == viewer end)

    Enum.each(gone, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)
    maybe_idle(%{state | viewers: Map.new(viewers)})
  end

  defp maybe_idle(%{viewers: viewers, idle_timer: nil} = state) when map_size(viewers) == 0 do
    %{state | idle_timer: schedule_idle()}
  end

  defp maybe_idle(state), do: state

  defp cancel_idle(%{idle_timer: nil} = state), do: state

  defp cancel_idle(%{idle_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  defp schedule_idle do
    Process.send_after(self(), :idle_timeout, Preview.idle_ms())
  end

  defp append_log(log, chunk) do
    combined = log <> chunk
    overflow = byte_size(combined) - @log_limit

    if overflow > 0 do
      binary_part(combined, overflow, @log_limit)
    else
      combined
    end
  end
end
