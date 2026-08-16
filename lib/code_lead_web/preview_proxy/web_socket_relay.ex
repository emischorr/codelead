defmodule CodeLeadWeb.PreviewProxy.WebSocketRelay do
  @moduledoc """
  Websocket half of the preview proxy: a `WebSock` handler that dials
  the task's upstream with `Mint.WebSocket` and relays frames both
  ways — Vite HMR and Phoenix LiveView die without this.

  Bandit runs `WebSock` callbacks in the connection process, so the
  Mint socket (active mode) delivers straight into `handle_info/2`.
  Client frames arriving before the upstream handshake completes are
  buffered and flushed once it does; each leg answers its own pings.
  """

  @behaviour WebSock

  @typedoc """
  Upgrade argument: the upstream to dial, the (encoded) path + query to
  request, and the forwarded handshake headers.
  """
  @type config :: %{
          upstream: CodeLead.PreviewGateway.upstream(),
          path: String.t(),
          headers: [{String.t(), String.t()}]
        }

  @impl true
  def init(%{upstream: %{host: host, port: port}, path: path, headers: headers}) do
    with {:ok, conn} <- Mint.HTTP.connect(:http, host, port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers) do
      {:ok,
       %{
         conn: conn,
         ref: ref,
         websocket: nil,
         status: nil,
         resp_headers: [],
         pending: []
       }}
    else
      {:error, _reason} ->
        {:stop, {:shutdown, :upstream_unavailable}, {1011, "upstream unavailable"}, nil}

      {:error, _conn, _reason} ->
        {:stop, {:shutdown, :upstream_unavailable}, {1011, "upstream unavailable"}, nil}
    end
  end

  @impl true
  def handle_in({data, [opcode: opcode]}, %{websocket: nil} = state) do
    {:ok, %{state | pending: state.pending ++ [{opcode, data}]}}
  end

  def handle_in({data, [opcode: opcode]}, state) do
    send_upstream(state, {opcode, data})
  end

  @impl true
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, _conn, _error, _responses} ->
        {:stop, {:shutdown, :upstream_error}, {1011, "upstream error"}, state}

      :unknown ->
        {:ok, state}
    end
  end

  @impl true
  def terminate(_reason, %{websocket: websocket} = state) when websocket != nil do
    # Best effort: tell the upstream the client went away.
    with {:ok, _websocket, data} <- Mint.WebSocket.encode(websocket, {:close, 1001, ""}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      Mint.HTTP.close(conn)
    else
      _closed -> Mint.HTTP.close(state.conn)
    end

    :ok
  end

  def terminate(_reason, %{conn: conn}) do
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Upstream handshake + frames

  defp handle_responses(responses, state) do
    Enum.reduce_while(responses, {:ok, state}, fn response, {_tag, state} = acc ->
      case handle_response(response, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:push, frames, state} -> {:cont, merge_push(acc, frames, state)}
        stop -> {:halt, stop}
      end
    end)
  end

  defp merge_push({:push, earlier, _state}, frames, state), do: {:push, earlier ++ frames, state}
  defp merge_push({:ok, _state}, frames, state), do: {:push, frames, state}

  defp handle_response({:status, ref, status}, %{ref: ref} = state) do
    {:ok, %{state | status: status}}
  end

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state) do
    establish(%{state | resp_headers: state.resp_headers ++ headers})
  end

  defp handle_response({:done, ref}, %{ref: ref} = state), do: {:ok, state}

  defp handle_response({:data, ref, data}, %{ref: ref, websocket: websocket} = state)
       when websocket != nil do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        relay_frames(frames, %{state | websocket: websocket})

      {:error, _websocket, _reason} ->
        {:stop, {:shutdown, :upstream_error}, {1011, "upstream frame error"}, state}
    end
  end

  defp handle_response(_other, state), do: {:ok, state}

  defp establish(%{status: status} = state) when status != nil do
    case Mint.WebSocket.new(state.conn, state.ref, status, state.resp_headers) do
      {:ok, conn, websocket} ->
        flush_pending(%{state | conn: conn, websocket: websocket})

      {:error, _conn, _reason} ->
        {:stop, {:shutdown, :upstream_rejected}, {1011, "upstream rejected upgrade"}, state}
    end
  end

  defp establish(state), do: {:ok, state}

  defp flush_pending(%{pending: pending} = state) do
    Enum.reduce_while(pending, {:ok, %{state | pending: []}}, fn frame, {:ok, state} ->
      case send_upstream(state, frame) do
        {:ok, state} -> {:cont, {:ok, state}}
        stop -> {:halt, stop}
      end
    end)
  end

  defp relay_frames(frames, state) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, acc ->
      {_tag, state} = acc_state(acc)

      case relay_frame(frame, state) do
        {:ok, state} -> {:cont, put_state(acc, state)}
        {:push, new_frames, state} -> {:cont, merge_push(acc, new_frames, state)}
        stop -> {:halt, stop}
      end
    end)
  end

  defp acc_state({:ok, state}), do: {:ok, state}
  defp acc_state({:push, _frames, state}), do: {:push, state}

  defp put_state({:push, frames, _state}, state), do: {:push, frames, state}
  defp put_state({:ok, _state}, state), do: {:ok, state}

  defp relay_frame({:text, text}, state), do: {:push, [{:text, text}], state}
  defp relay_frame({:binary, binary}, state), do: {:push, [{:binary, binary}], state}

  # Each leg keeps its own connection alive: Bandit answers the
  # client's pings, we answer the upstream's.
  defp relay_frame({:ping, data}, state), do: send_upstream(state, {:pong, data})
  defp relay_frame({:pong, _data}, state), do: {:ok, state}

  defp relay_frame({:close, code, reason}, state) do
    {:stop, :normal, {code || 1000, reason || ""}, state}
  end

  defp send_upstream(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      {:error, _conn_or_ws, _reason} ->
        {:stop, {:shutdown, :upstream_error}, {1011, "upstream send failed"}, state}
    end
  end
end
