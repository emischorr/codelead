defmodule FrontSeat.WsEchoPlug do
  @moduledoc """
  In-test upstream plug that upgrades every request to the
  `FrontSeat.WsEchoServer` websocket handler.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    WebSockAdapter.upgrade(conn, FrontSeat.WsEchoServer, %{}, [])
  end
end
