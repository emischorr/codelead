defmodule CodeLead.Terminal.Session do
  @moduledoc """
  One shell per task: owns the Port (so a page refresh kills only the
  LiveView, never the shell), keeps a bounded scrollback for repainting
  reconnecting viewers, broadcasts output over the task's terminal
  topic, and forwards window resizes to the injected `resizer` (a no-op
  without a PTY). Stops itself when the shell exits or after sitting
  viewer-less past the idle timeout; `restart: :temporary` — a dead
  shell is restarted by the UI on demand, not by the supervisor.

  Traps exits so that every way out runs the `stopper` — an application
  shutdown and a torn-down execution context included. Closing the Port
  only makes the shell see EOF, which reaches its foreground children at
  best and nothing at all through `docker exec` (ADR-0013).
  """

  use GenServer, restart: :temporary, shutdown: 10_000

  alias CodeLead.Terminal

  @scrollback_limit 200_000

  @type start_arg :: %{
          task_id: pos_integer(),
          pty?: boolean(),
          port_opener: (-> port()),
          stopper: (pos_integer() | nil -> :ok),
          resizer: (pos_integer(), pos_integer() -> any())
        }

  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link(%{task_id: task_id} = arg) do
    GenServer.start_link(__MODULE__, arg, name: Terminal.via(task_id))
  end

  @impl true
  def init(%{
        task_id: task_id,
        pty?: pty?,
        port_opener: port_opener,
        stopper: stopper,
        resizer: resizer
      }) do
    Process.flag(:trap_exit, true)
    port = port_opener.()
    # After the port opens, never before: `terminate/2` does not run if
    # `init/1` raises, and this is the only thing here that can — an
    # earlier announcement would leave an open with no matching close.
    Terminal.broadcast_session(task_id, :opened)

    {:ok,
     %{
       task_id: task_id,
       port: port,
       # Resolved now, not at stop time: a port that has already exited
       # reports no os pid, and the group it led may still hold members
       # — precisely the background children a stop has to reap.
       os_pid: os_pid(port),
       pty?: pty?,
       stopper: stopper,
       resizer: resizer,
       scrollback: <<>>,
       viewers: %{},
       idle_timer: schedule_idle(nil)
     }}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    state = stop_shell(state)
    Terminal.broadcast(state.task_id, {:terminal_exit, state.task_id, :stopped})
    {:stop, :normal, :ok, state}
  end

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

  def handle_cast({:resize, _cols, _rows}, %{pty?: false} = state), do: {:noreply, state}

  def handle_cast({:resize, cols, rows}, state) do
    # Resizing shells out — a `docker exec` for container tasks — so it
    # runs detached: this process must keep broadcasting output meanwhile,
    # and a failed resize must not take the shell down with it.
    spawn(fn -> state.resizer.(cols, rows) end)
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
    # Ahead of the stopper: a container stopper waits up to 5s on a
    # `docker exec`, and the readout should not lag the decision.
    Terminal.broadcast_session(state.task_id, :closed)
    state |> stop_shell() |> close_port()
  end

  # Clearing the stopper is what makes this safe to call from every exit
  # path, `terminate/2` included, without signalling twice.
  defp stop_shell(%{stopper: nil} = state), do: state

  defp stop_shell(%{stopper: stopper, os_pid: os_pid} = state) do
    stopper.(os_pid)
    %{state | stopper: nil}
  rescue
    _cannot_signal -> %{state | stopper: nil}
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp close_port(%{port: port} = _state) do
    if Port.info(port), do: Port.close(port)
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
