defmodule CodeLead.WsEchoPlug do
  @moduledoc """
  In-test upstream plug that upgrades every request to the
  `CodeLead.WsEchoServer` websocket handler.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    WebSockAdapter.upgrade(conn, CodeLead.WsEchoServer, %{}, [])
  end
end
