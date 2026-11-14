defmodule FrontSeatWeb.ErrorJSON do
  @moduledoc """
  Renders JSON errors raised outside a controller's own handling — an
  unknown `/api` route, a crash — in the same shape `/api` controllers use
  (`FrontSeatWeb.Api.Error`), so a client parses every error one way.
  """

  alias FrontSeatWeb.Api.Error

  @spec render(String.t(), map()) :: map()
  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)
    Error.body(code(template), message <> ".", nil)
  end

  defp code("404.json"), do: :not_found
  defp code("406.json"), do: :not_acceptable
  defp code("500.json"), do: :internal_error
  defp code(_template), do: :error
end
