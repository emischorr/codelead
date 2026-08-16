defmodule CodeLead.Terminal.Session do
  @moduledoc """
  One shell per task: owns the Port (so a page refresh kills only the
  LiveView, never the shell), keeps a bounded scrollback for repainting
  reconnecting viewers, and broadcasts output over the task's terminal
  topic. Stops itself when the shell exits or after sitting viewer-less
  past the idle timeout; `restart: :temporary` — a dead shell is
  restarted by the UI on demand, not by the supervisor.
  """

  use GenServer, restart: :temporary

  alias CodeLead.Terminal

  @scrollback_limit 200_000

  @type start_arg :: %{
          task_id: pos_integer(),
          pty?: boolean(),
          port_opener: (-> port())
        }

  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link(%{task_id: task_id} = arg) do
    GenServer.start_link(__MODULE__, arg, name: Terminal.via(task_id))
  end

  @impl true
  def init(%{task_id: task_id, pty?: pty?, port_opener: port_opener}) do
    port = port_opener.()

    {:ok,
     %{
       task_id: task_id,
       port: port,
       pty?: pty?,
       scrollback: <<>>,
       viewers: %{},
       idle_timer: schedule_idle(nil)
     }}
  end

  @impl true
  def handle_call({:attach, viewer}, _from, state) do
    ref = Process.monitor(viewer)
    state = %{state | viewers: Map.put(state.viewers, ref, viewer)}
    {:reply, {:ok, state.scrollback, state.pty?}, cancel_idle(state)}
  end

  def handle_call({:detach, viewer}, _from, state) do
    {:reply, :ok, drop_viewer(state, viewer)}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    Port.command(state.port, data)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    Terminal.broadcast(state.task_id, {:terminal_data, state.task_id, chunk})
    {:noreply, %{state | scrollback: append_scrollback(state.scrollback, chunk)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Terminal.broadcast(state.task_id, {:terminal_exit, state.task_id, status})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.viewers, ref) do
      {nil, _viewers} -> {:noreply, state}
      {_pid, viewers} -> {:noreply, maybe_idle(%{state | viewers: viewers})}
    end
  end

  def handle_info(:idle_timeout, %{viewers: viewers} = state) when map_size(viewers) == 0 do
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

  defp drop_viewer(state, viewer) do
    {gone, viewers} =
      Enum.split_with(state.viewers, fn {_ref, pid} -> pid == viewer end)

    Enum.each(gone, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)
    maybe_idle(%{state | viewers: Map.new(viewers)})
  end

  defp maybe_idle(%{viewers: viewers, idle_timer: nil} = state) when map_size(viewers) == 0 do
    %{state | idle_timer: schedule_idle(nil)}
  end

  defp maybe_idle(state), do: state

  defp cancel_idle(%{idle_timer: nil} = state), do: state

  defp cancel_idle(%{idle_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  defp schedule_idle(_timer) do
    Process.send_after(self(), :idle_timeout, Terminal.idle_ms())
  end

  defp append_scrollback(scrollback, chunk) do
    combined = scrollback <> chunk
    overflow = byte_size(combined) - @scrollback_limit

    if overflow > 0 do
      binary_part(combined, overflow, @scrollback_limit)
    else
      combined
    end
  end
end
