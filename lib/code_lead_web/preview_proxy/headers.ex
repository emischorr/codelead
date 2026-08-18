defmodule CodeLeadWeb.PreviewProxy.Headers do
  @moduledoc """
  Header hygiene for the preview proxy. Strips hop-by-hop headers both
  directions, rewrites `host`, stamps `x-forwarded-*`, rewrites
  root-relative `location` redirects back onto the preview prefix, and
  gives the previewed app its own cookie jar on CodeLead's origin by
  namespacing every cookie per task (see `mount/1`). Bodies are never
  touched — base paths are the dev server's job via `PREVIEW_BASE_PATH`.
  """

  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @cookie_namespace "_clp"

  @type headers :: [{String.t(), String.t()}]

  @typedoc "Per-task mount: the external path prefix and the cookie-name prefix."
  @type mount :: %{path: String.t(), cookie_prefix: String.t()}

  @doc """
  The proxy mount for a task: the path everything is served under, and
  the cookie-name prefix that keeps the previewed app's cookies apart
  from CodeLead's own and from sibling previews.
  """
  @spec mount(integer() | String.t()) :: mount()
  def mount(task_id) do
    %{path: "/preview/#{task_id}", cookie_prefix: "#{@cookie_namespace}#{task_id}_"}
  end

  @doc """
  Request headers to send upstream, derived from the incoming conn.
  """
  @spec request_headers(Plug.Conn.t(), CodeLead.PreviewGateway.upstream(), mount()) :: headers()
  def request_headers(conn, %{host: host, port: port}, %{
        path: path,
        cookie_prefix: cookie_prefix
      }) do
    conn.req_headers
    |> strip_hop_by_hop()
    |> List.keydelete("host", 0)
    |> List.keydelete("content-length", 0)
    |> rewrite_cookies(cookie_prefix)
    |> Kernel.++([
      {"host", "#{host}:#{port}"},
      {"x-forwarded-for", peer_ip(conn)},
      {"x-forwarded-proto", Atom.to_string(conn.scheme)},
      {"x-forwarded-host", conn.host},
      {"x-forwarded-prefix", path}
    ])
  end

  @doc """
  Response headers to send back to the browser. `content-length` and
  `transfer-encoding` are dropped because the proxy re-chunks the body.
  `scheme` is the browser's view of the origin — `Secure` cookies are
  void when it is `:http`.
  """
  @spec response_headers(headers(), mount(), :http | :https) :: headers()
  def response_headers(headers, %{path: path, cookie_prefix: cookie_prefix}, scheme) do
    headers
    |> strip_hop_by_hop()
    |> List.keydelete("content-length", 0)
    |> Enum.flat_map(&rewrite_response_header(&1, path, cookie_prefix, scheme == :https))
  end

  @doc """
  Websocket handshake headers to send upstream: the request headers
  minus the handshake fields the upstream client re-negotiates itself.
  """
  @spec ws_request_headers(Plug.Conn.t(), CodeLead.PreviewGateway.upstream(), mount()) ::
          headers()
  def ws_request_headers(conn, upstream, mount) do
    conn
    |> request_headers(upstream, mount)
    |> Enum.reject(fn {name, _value} ->
      name in ~w(host sec-websocket-key sec-websocket-version sec-websocket-extensions)
    end)
  end

  defp strip_hop_by_hop(headers) do
    Enum.reject(headers, fn {name, _value} -> name in @hop_by_hop end)
  end

  # Mint canonicalizes response header names to lowercase.
  defp rewrite_response_header({"location", "/" <> _rest = location}, path, _prefix, _secure?),
    do: [{"location", path <> location}]

  defp rewrite_response_header({"set-cookie", value}, path, cookie_prefix, secure?),
    do: namespace_cookie(value, cookie_prefix, path, secure?)

  defp rewrite_response_header(header, _path, _cookie_prefix, _secure?), do: [header]

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

  # Only this task's cookies go upstream, with the namespace peeled off,
  # so the previewed app sees exactly the jar it wrote. Everything else
  # on the shared origin stays in the browser — CodeLead's session and
  # remember-me cookies have no business inside an agent's container, and
  # another task's preview has no business seeing this one's.
  defp rewrite_cookies(headers, cookie_prefix) do
    Enum.flat_map(headers, fn
      {"cookie", value} ->
        case task_cookies(value, cookie_prefix) do
          "" -> []
          forwarded -> [{"cookie", forwarded}]
        end

      other ->
        [other]
    end)
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
