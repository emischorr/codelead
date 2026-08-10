defmodule CodeLead.Acp.JsonRpc do
  @moduledoc """
  Thin JSON-RPC 2.0 subset for the Agent Client Protocol: newline-
  delimited JSON frames over stdio. Encoding returns iodata ending in a
  newline; decoding classifies a single frame.
  """

  @type decoded ::
          {:request, id :: term(), method :: String.t(), params :: map()}
          | {:notification, method :: String.t(), params :: map()}
          | {:response, id :: term(), result :: term()}
          | {:error_response, id :: term(), error :: map()}
          | {:invalid, term()}

  @spec encode_request(term(), String.t(), map()) :: iodata()
  def encode_request(id, method, params) do
    frame(%{jsonrpc: "2.0", id: id, method: method, params: params})
  end

  @spec encode_notification(String.t(), map()) :: iodata()
  def encode_notification(method, params) do
    frame(%{jsonrpc: "2.0", method: method, params: params})
  end

  @spec encode_response(term(), term()) :: iodata()
  def encode_response(id, result) do
    frame(%{jsonrpc: "2.0", id: id, result: result})
  end

  @spec encode_error(term(), integer(), String.t()) :: iodata()
  def encode_error(id, code, message) do
    frame(%{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
  end

  @spec decode(String.t()) :: decoded()
  def decode(line) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "method" => method} = frame} ->
        {:request, id, method, frame["params"] || %{}}

      {:ok, %{"method" => method} = frame} ->
        {:notification, method, frame["params"] || %{}}

      {:ok, %{"id" => id, "error" => error}} ->
        {:error_response, id, error}

      {:ok, %{"id" => id} = frame} ->
        {:response, id, frame["result"]}

      other ->
        {:invalid, other}
    end
  end

  defp frame(map), do: [Jason.encode_to_iodata!(map), ?\n]
end
