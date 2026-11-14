defmodule FrontSeatWeb.Api.Error do
  @moduledoc """
  The one error shape every `/api` response uses (see `docs/api.md`):

      {"error": {"code": "not_found", "message": "Project not found.", "fields": {...}}}

  `code` is machine-readable and stable; `message` is meant to be shown to
  a person as is; `fields` appears only on validation failures.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  @type code ::
          :unauthorized
          | :license_required
          | :not_found
          | :validation_failed
          | :setup_required
          | atom()

  @doc """
  Sends the error response and halts the connection.
  """
  @spec send_error(Plug.Conn.t(), pos_integer(), code(), String.t(), map() | nil) ::
          Plug.Conn.t()
  def send_error(conn, status, code, message, fields \\ nil) do
    conn
    |> put_status(status)
    |> json(body(code, message, fields))
    |> halt()
  end

  @doc """
  The JSON body for an error, for callers that render rather than send.
  """
  @spec body(code(), String.t(), map() | nil) :: map()
  def body(code, message, nil), do: %{error: %{code: code, message: message}}
  def body(code, message, fields), do: %{error: %{code: code, message: message, fields: fields}}

  @doc """
  Per-field messages from a changeset, interpolated:
  `%{"title" => ["can't be blank"]}`.
  """
  @spec changeset_fields(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def changeset_fields(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
