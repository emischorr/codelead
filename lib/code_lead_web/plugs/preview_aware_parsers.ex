defmodule CodeLeadWeb.Plugs.PreviewAwareParsers do
  @moduledoc """
  `Plug.Parsers`, except `/preview/*` requests pass through with their
  body unread — the reverse proxy must forward the raw bytes, and a
  parsed-and-discarded body cannot be re-read from the adapter.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(%Plug.Conn{path_info: ["preview" | _rest]} = conn, _opts), do: conn
  def call(conn, opts), do: Plug.Parsers.call(conn, opts)
end
