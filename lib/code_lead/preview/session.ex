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
  """

  use GenServer, restart: :temporary

  alias CodeLead.Preview

  @log_limit 64_000
  @probe_interval_ms 1_000

  @type start_arg :: %{
          task_id: pos_integer(),
          port_opener: (-> port()),
          stopper: (port() -> :ok),
          probe: (-> :ready | :waiting)
        }

  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link(%{task_id: task_id} = arg) do
    GenServer.start_link(__MODULE__, arg, name: Preview.via(task_id))
  end

  @impl true
  def init(%{task_id: task_id, port_opener: port_opener, stopper: stopper, probe: probe}) do
    port = port_opener.()
    Preview.broadcast(task_id, :starting)
    Process.send_after(self(), :probe, @probe_interval_ms)
    start_timer = Process.send_after(self(), :start_timeout, Preview.start_timeout_ms())

    {:ok,
     %{
       task_id: task_id,
       port: port,
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
    stop_server(state)
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

  def handle_info(:start_timeout, %{status: :starting} = state) do
    stop_server(state)
    Preview.broadcast(state.task_id, {:failed, state.log})
    {:stop, :normal, state}
  end

  def handle_info(:start_timeout, state), do: {:noreply, state}

  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {:noreply, %{state | log: append_log(state.log, chunk)}}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port, status: :starting} = state) do
    Preview.broadcast(state.task_id, {:failed, state.log})
    {:stop, :normal, state}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
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
    stop_server(state)
    Preview.broadcast(state.task_id, :stopped)
    {:stop, :normal, state}
  end

  def handle_info(:idle_timeout, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  catch
    # The port can die between the info check and the close.
    :error, :badarg -> :ok
  end

  # The server process outlives its Port (docker exec's death never
  # reaches into the container; a shell's children survive an EOF), so
  # stopping means signalling it explicitly.
  defp stop_server(state) do
    state.stopper.(state.port)
  rescue
    _cannot_signal -> :ok
  end

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
