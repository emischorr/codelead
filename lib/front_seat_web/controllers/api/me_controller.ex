defmodule FrontSeatWeb.Api.MeController do
  @moduledoc """
  `GET /api/v1/me` — who the token acts as, so a client can verify its
  configuration.
  """

  use FrontSeatWeb, :controller

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(%{assigns: %{current_scope: %{user: user, role: role}}} = conn, _params) do
    json(conn, %{data: %{id: user.id, username: user.username, role: role}})
  end
end
