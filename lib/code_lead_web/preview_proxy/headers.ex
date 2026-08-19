defmodule CodeLeadWeb.PreviewProxy.Headers do
  @moduledoc """
  Header hygiene for the preview proxy. Strips hop-by-hop headers both
  directions, rewrites `host`, and stamps `x-forwarded-*` for every
  gateway. What else happens is decided by the task's
  `CodeLeadWeb.PreviewProxy.Policy`: under the path gateway,
  root-relative `location` redirects are rewritten back onto the preview
  prefix and the previewed app gets its own cookie jar on CodeLead's
  origin by namespacing every cookie per task; under the subdomain
  gateway the preview owns a real origin and both rewrites retire.
  Bodies are never touched — base paths are the dev server's job via
  `PREVIEW_BASE_PATH`.
  """

  alias CodeLeadWeb.PreviewProxy.Policy

  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)

  @type headers :: [{String.t(), String.t()}]

  @doc """
  Request headers to send upstream, derived from the incoming conn.
  """
  @spec request_headers(Plug.Conn.t(), CodeLead.PreviewGateway.upstream(), Policy.t()) ::
          headers()
  def request_headers(conn, %{host: host, port: port}, %Policy{} = policy) do
    conn.req_headers
    |> strip_hop_by_hop()
    |> List.keydelete("host", 0)
    |> List.keydelete("content-length", 0)
    |> rewrite_cookies(policy)
    |> Kernel.++(
      [
        {"host", "#{host}:#{port}"},
        {"x-forwarded-for", peer_ip(conn)},
        {"x-forwarded-proto", Atom.to_string(conn.scheme)},
        {"x-forwarded-host", conn.host}
      ] ++ forwarded_prefix(policy)
    )
  end

  @doc """
  Response headers to send back to the browser. `content-length` and
  `transfer-encoding` are dropped because the proxy re-chunks the body.
  `scheme` is the browser's view of the origin — `Secure` cookies are
  void when it is `:http`.
  """
  @spec response_headers(headers(), Policy.t(), :http | :https) :: headers()
  def response_headers(headers, %Policy{} = policy, scheme) do
    headers
    |> strip_hop_by_hop()
    |> List.keydelete("content-length", 0)
    |> Enum.flat_map(&rewrite_response_header(&1, policy, scheme == :https))
  end

  @doc """
  Websocket handshake headers to send upstream: the request headers
  minus the handshake fields the upstream client re-negotiates itself.
  """
  @spec ws_request_headers(Plug.Conn.t(), CodeLead.PreviewGateway.upstream(), Policy.t()) ::
          headers()
  def ws_request_headers(conn, upstream, policy) do
    conn
    |> request_headers(upstream, policy)
    |> Enum.reject(fn {name, _value} ->
      name in ~w(host sec-websocket-key sec-websocket-version sec-websocket-extensions)
    end)
  end

  defp strip_hop_by_hop(headers) do
    Enum.reject(headers, fn {name, _value} -> name in @hop_by_hop end)
  end

  defp forwarded_prefix(%Policy{mount_path: ""}), do: []
  defp forwarded_prefix(%Policy{mount_path: path}), do: [{"x-forwarded-prefix", path}]

  # Mint canonicalizes response header names to lowercase.
  defp rewrite_response_header(
         {"location", "/" <> _rest = location},
         %Policy{rewrite_location?: true, mount_path: path},
         _secure?
       ),
       do: [{"location", path <> location}]

  defp rewrite_response_header(
         {"set-cookie", value},
         %Policy{cookie_prefix: prefix, mount_path: path},
         secure?
       )
       when is_binary(prefix),
       do: namespace_cookie(value, prefix, path, secure?)

  defp rewrite_response_header(header, _policy, _secure?), do: [header]

  # The previewed app shares CodeLead's origin, so its cookies get their
  # own namespace: the name is prefixed (a previewed CodeLead can no
  # longer clobber `_code_lead_key` and log the operator out of their own
  # instance), `Path` is folded under the mount, `Domain` is dropped so
  # the cookie stays host-only, and attributes a browser would reject
  # over plain http (`Secure`, `Partitioned`, `SameSite=None`) go with it
  # — keeping them voids the whole cookie. `__Host-`/`__Secure-` names
  # lose their magic by being renamed, which is what lets them survive
  # the re-pathing; the original name is restored on the way upstream.
  defp namespace_cookie(value, cookie_prefix, path, secure?) do
    [pair | attrs] = String.split(value, ";")

    attrs = attrs |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case String.split(String.trim(pair), "=", parts: 2) do
      [name, cookie_value] when name != "" ->
        cookie = [
          cookie_prefix <> name <> "=" <> cookie_value,
          "Path=" <> mount_path(Enum.find_value(attrs, &path_attribute/1), path)
          | Enum.reject(attrs, &drop_attribute?(&1, secure?))
        ]

        [{"set-cookie", Enum.join(cookie, "; ")}]

      _unnamed ->
        []
    end
  end

  defp mount_path("/", path), do: path
  defp mount_path("/" <> _rest = upstream_path, path), do: path <> upstream_path
  defp mount_path(_absent_or_relative, path), do: path

  defp path_attribute(attr) do
    if attribute_name(attr) == "path", do: attribute_value(attr)
  end

  defp drop_attribute?(attr, secure?) do
    case attribute_name(attr) do
      "path" -> true
      "domain" -> true
      "secure" -> not secure?
      "partitioned" -> not secure?
      "samesite" -> not secure? and String.downcase(attribute_value(attr) || "") == "none"
      _other -> false
    end
  end

  defp attribute_name(attr) do
    attr |> String.split("=", parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  defp attribute_value(attr) do
    case String.split(attr, "=", parts: 2) do
      [_name, value] -> String.trim(value)
      [_flag] -> nil
    end
  end

  # Path gateway: only this task's cookies go upstream, with the
  # namespace peeled off, so the previewed app sees exactly the jar it
  # wrote. Everything else on the shared origin stays in the browser —
  # CodeLead's session and remember-me cookies have no business inside an
  # agent's container, and another task's preview has no business seeing
  # this one's. Subdomain gateway: the preview owns its origin, so the
  # jar passes verbatim minus the preview host's own session cookie.
  defp rewrite_cookies(headers, %Policy{cookie_prefix: nil, strip_request_cookies: strip}) do
    map_cookie_header(headers, &drop_cookies(&1, strip))
  end

  defp rewrite_cookies(headers, %Policy{cookie_prefix: cookie_prefix}) do
    map_cookie_header(headers, &task_cookies(&1, cookie_prefix))
  end

  defp map_cookie_header(headers, fun) do
    Enum.flat_map(headers, fn
      {"cookie", value} ->
        case fun.(value) do
          "" -> []
          forwarded -> [{"cookie", forwarded}]
        end

      other ->
        [other]
    end)
  end

  defp drop_cookies(cookie_value, strip_names) do
    cookie_value
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [name, _value] -> name in strip_names
        [_unnamed] -> true
      end
    end)
    |> Enum.join("; ")
  end

  defp task_cookies(cookie_value, cookie_prefix) do
    cookie_value
    |> String.split(";")
    |> Enum.flat_map(&unnamespace_cookie(String.trim(&1), cookie_prefix))
    |> Enum.join("; ")
  end

  defp unnamespace_cookie(pair, cookie_prefix) do
    case String.split(pair, "=", parts: 2) do
      [name, value] ->
        # `replace_prefix/3` returns the input unchanged when the prefix
        # does not match — that pin is the "not ours" branch.
        case String.replace_prefix(name, cookie_prefix, "") do
          ^name -> []
          "" -> []
          stripped -> [stripped <> "=" <> value]
        end

      _unnamed ->
        []
    end
  end

  defp peer_ip(%Plug.Conn{remote_ip: remote_ip}) do
    remote_ip |> :inet.ntoa() |> to_string()
  end
end
