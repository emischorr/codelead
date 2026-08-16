defmodule CodeLeadWeb.PreviewProxy.WebSocketRelayTest do
  use ExUnit.Case, async: true

  alias CodeLeadWeb.PreviewProxy.WebSocketRelay

  # The relay runs its callbacks in whatever process owns the client
  # connection — here, the test process, so the Mint socket's active-mode
  # messages land in our mailbox and are pumped into `handle_info/2`.

  setup do
    upstream =
      start_supervised!(
        {Bandit, plug: CodeLead.WsEchoPlug, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(upstream)

    %{config: %{upstream: %{host: "127.0.0.1", port: port}, path: "/ws", headers: []}}
  end

  test "relays a frame sent before the handshake completes and echoes it back", %{config: config} do
    {:ok, state} = WebSocketRelay.init(config)

    # Client speaks immediately; the relay buffers until the upstream 101.
    {:ok, state} = WebSocketRelay.handle_in({"hello", [opcode: :text]}, state)

    assert {frames, _state} = pump_until_push(state)
    assert {:text, "hello"} in frames
  end

  test "relays frames after establishment, both text and binary", %{config: config} do
    {:ok, state} = WebSocketRelay.init(config)
    {:ok, state} = WebSocketRelay.handle_in({"warmup", [opcode: :text]}, state)
    {frames, state} = pump_until_push(state)
    assert {:text, "warmup"} in frames

    {:ok, state} = WebSocketRelay.handle_in({<<1, 2, 3>>, [opcode: :binary]}, state)
    {frames, _state} = pump_until_push(state)
    assert {:binary, <<1, 2, 3>>} in frames
  end

  test "an upstream close becomes a client close with the upstream's code", %{config: config} do
    {:ok, state} = WebSocketRelay.init(config)
    {:ok, state} = WebSocketRelay.handle_in({"bye", [opcode: :text]}, state)

    assert {:stop, _reason, {1000, _detail}, _state} = pump_until_stop(state)
  end

  test "an unreachable upstream refuses the socket with 1011" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, dead_port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    config = %{upstream: %{host: "127.0.0.1", port: dead_port}, path: "/ws", headers: []}

    assert {:stop, {:shutdown, :upstream_unavailable}, {1011, _msg}, _state} =
             WebSocketRelay.init(config)
  end

  defp pump_until_push(state) do
    receive do
      message ->
        case WebSocketRelay.handle_info(message, state) do
          {:ok, state} -> pump_until_push(state)
          {:push, frames, state} -> {List.wrap(frames), state}
          other -> flunk("relay stopped while awaiting a push: #{inspect(other)}")
        end
    after
      2_000 -> flunk("no push arrived from the relay")
    end
  end

  defp pump_until_stop(state) do
    receive do
      message ->
        case WebSocketRelay.handle_info(message, state) do
          {:ok, state} -> pump_until_stop(state)
          {:push, _frames, state} -> pump_until_stop(state)
          stop -> stop
        end
    after
      2_000 -> flunk("the relay never stopped")
    end
  end
end
