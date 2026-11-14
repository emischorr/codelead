defmodule FrontSeatWeb.Api.FallbackController do
  @moduledoc """
  Turns context error tuples into the `/api` error shape. Authorization
  refusals on project-keyed resources are 404, not 403: a caller who
  cannot see a project must not learn that it exists.
  """

  use FrontSeatWeb, :controller

  alias FrontSeatWeb.Api.Error

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, {:error, :not_found}), do: not_found(conn)
  def call(conn, {:error, :unauthorized}), do: not_found(conn)

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    validation_failed(conn, Error.changeset_fields(changeset))
  end

  def call(conn, {:error, {:invalid_params, fields}}), do: validation_failed(conn, fields)

  defp not_found(conn), do: Error.send_error(conn, 404, :not_found, "Not found.")

  defp validation_failed(conn, fields) do
    Error.send_error(conn, 422, :validation_failed, "The request has invalid fields.", fields)
  end
end
