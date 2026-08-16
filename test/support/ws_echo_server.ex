defmodule CodeLead.WsEchoServer do
  @moduledoc """
  In-test websocket echo handler: pushes every data frame back, and
  closes with 1000/"bye" when told to. The upstream half of the preview
  relay tests (served by `CodeLead.WsEchoPlug`).
  """

  @behaviour WebSock

  @impl true
  def init(_state), do: {:ok, %{}}

  @impl true
  def handle_in({"bye", [opcode: :text]}, state), do: {:stop, :normal, {1000, "bye"}, state}
  def handle_in({data, [opcode: opcode]}, state), do: {:push, {opcode, data}, state}

  @impl true
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
