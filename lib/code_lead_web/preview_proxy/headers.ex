defmodule CodeLeadWeb.PreviewProxy.Headers do
  @moduledoc """
  Header hygiene for the preview proxy. Strips hop-by-hop headers both
  directions, rewrites `host`, stamps `x-forwarded-*`, keeps the app's
  own session cookie out of the upstream, and rewrites root-relative
  `location` redirects back onto the preview prefix — the single piece
  of response rewriting the proxy does (bodies are never touched; base
  paths are the dev server's job via `PREVIEW_BASE_PATH`).
  """

  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @session_cookie "_code_lead_key"

  @type headers :: [{String.t(), String.t()}]

  @doc """
  Request headers to send upstream, derived from the incoming conn.
  """
  @spec request_headers(Plug.Conn.t(), CodeLead.PreviewGateway.upstream(), String.t()) ::
          headers()
  def request_headers(conn, %{host: host, port: port}, prefix) do
    conn.req_headers
    |> strip_hop_by_hop()
    |> List.keydelete("host", 0)
    |> List.keydelete("content-length", 0)
    |> rewrite_cookie()
    |> Kernel.++([
      {"host", "#{host}:#{port}"},
      {"x-forwarded-for", peer_ip(conn)},
      {"x-forwarded-proto", Atom.to_string(conn.scheme)},
      {"x-forwarded-host", conn.host},
      {"x-forwarded-prefix", prefix}
    ])
  end

  @doc """
  Response headers to send back to the browser. `content-length` and
  `transfer-encoding` are dropped because the proxy re-chunks the body.
  """
  @spec response_headers(headers(), String.t()) :: headers()
  def response_headers(headers, prefix) do
    headers
    |> strip_hop_by_hop()
    |> List.keydelete("content-length", 0)
    |> Enum.map(fn
      {"location", "/" <> _rest = location} -> {"location", prefix <> location}
      other -> other
    end)
  end

  @doc """
  Websocket handshake headers to send upstream: the request headers
  minus the handshake fields the upstream client re-negotiates itself.
  """
  @spec ws_request_headers(Plug.Conn.t(), CodeLead.PreviewGateway.upstream(), String.t()) ::
          headers()
  def ws_request_headers(conn, upstream, prefix) do
    conn
    |> request_headers(upstream, prefix)
    |> Enum.reject(fn {name, _value} ->
      name in ~w(host sec-websocket-key sec-websocket-version sec-websocket-extensions)
    end)
  end

  defp strip_hop_by_hop(headers) do
    Enum.reject(headers, fn {name, _value} -> name in @hop_by_hop end)
  end

  # The signed CodeLead session cookie is meaningless upstream and has
  # no business inside user containers; every other cookie passes
  # through (accepted same-origin MVP tradeoff).
  defp rewrite_cookie(headers) do
    case List.keyfind(headers, "cookie", 0) do
      nil ->
        headers

      {"cookie", value} ->
        case strip_session_cookie(value) do
          "" -> List.keydelete(headers, "cookie", 0)
          stripped -> List.keyreplace(headers, "cookie", 0, {"cookie", stripped})
        end
    end
  end

  @doc false
  @spec strip_session_cookie(String.t()) :: String.t()
  def strip_session_cookie(cookie_value) do
    cookie_value
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&String.starts_with?(&1, @session_cookie <> "="))
    |> Enum.join("; ")
  end

  defp peer_ip(%Plug.Conn{remote_ip: remote_ip}) do
    remote_ip |> :inet.ntoa() |> to_string()
  end
end
