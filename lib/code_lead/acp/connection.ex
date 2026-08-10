defmodule CodeLead.Acp.Connection do
  @moduledoc """
  Erlang Port bridge for one ACP agent subprocess. Owns the port,
  frames/parses newline-delimited JSON-RPC, correlates request ids, and
  forwards traffic to its owner process as messages:

    * `{:acp_response, ref, {:ok, result} | {:error, error}}` — reply to
      an outgoing `request/3`
    * `{:acp_request, id, method, params}` — incoming agent→client
      request; owner must `respond/3` or `respond_error/4`
    * `{:acp_notification, method, params}`
    * `{:acp_closed, exit_status}` — the subprocess exited
  """

  use GenServer

  alias CodeLead.Acp.JsonRpc

  ## Client API

  @doc """
  Starts the bridge. `opts` require `:port_opener`, a zero-arity fun
  executed inside the GenServer so it owns the port (e.g. wrapping
  `Executor.spawn/3`). Events go to `:owner` (defaults to the caller).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    owner = Keyword.get(opts, :owner, self())
    port_opener = Keyword.fetch!(opts, :port_opener)
    GenServer.start_link(__MODULE__, %{owner: owner, port_opener: port_opener})
  end

  @doc """
  Sends a request; the response arrives as `{:acp_response, ref, ...}`.
  """
  @spec request(pid(), String.t(), map()) :: reference()
  def request(conn, method, params) do
    ref = make_ref()
    GenServer.cast(conn, {:request, ref, method, params})
    ref
  end

  @spec notify(pid(), String.t(), map()) :: :ok
  def notify(conn, method, params) do
    GenServer.cast(conn, {:notify, method, params})
  end

  @spec respond(pid(), term(), term()) :: :ok
  def respond(conn, id, result) do
    GenServer.cast(conn, {:respond, id, result})
  end

  @spec respond_error(pid(), term(), integer(), String.t()) :: :ok
  def respond_error(conn, id, code, message) do
    GenServer.cast(conn, {:respond_error, id, code, message})
  end

  @spec close(pid()) :: :ok
  def close(conn) do
    GenServer.cast(conn, :close)
  end

  ## GenServer callbacks

  @impl GenServer
  def init(%{owner: owner, port_opener: port_opener}) do
    case port_opener.() do
      {:ok, port} ->
        {:ok,
         %{
           owner: owner,
           port: port,
           buffer: "",
           next_id: 1,
           pending: %{}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast({:request, ref, method, params}, state) do
    id = state.next_id
    send_frame(state.port, JsonRpc.encode_request(id, method, params))

    {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, ref)}}
  end

  def handle_cast({:notify, method, params}, state) do
    send_frame(state.port, JsonRpc.encode_notification(method, params))
    {:noreply, state}
  end

  def handle_cast({:respond, id, result}, state) do
    send_frame(state.port, JsonRpc.encode_response(id, result))
    {:noreply, state}
  end

  def handle_cast({:respond_error, id, code, message}, state) do
    send_frame(state.port, JsonRpc.encode_error(id, code, message))
    {:noreply, state}
  end

  def handle_cast(:close, state) do
    if state.port, do: safe_close(state.port)
    {:stop, :normal, %{state | port: nil}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> data)
    state = Enum.reduce(lines, %{state | buffer: buffer}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    send(state.owner, {:acp_closed, status})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  defp handle_line(line, state) do
    case JsonRpc.decode(line) do
      {:response, id, result} ->
        pop_pending(state, id, {:ok, result})

      {:error_response, id, error} ->
        pop_pending(state, id, {:error, error})

      {:request, id, method, params} ->
        send(state.owner, {:acp_request, id, method, params})
        state

      {:notification, method, params} ->
        send(state.owner, {:acp_notification, method, params})
        state

      {:invalid, _reason} ->
        state
    end
  end

  defp pop_pending(state, id, reply) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {ref, pending} ->
        send(state.owner, {:acp_response, ref, reply})
        %{state | pending: pending}
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(String.trim(&1) == "")), rest}
  end

  defp send_frame(port, iodata), do: Port.command(port, iodata)

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
