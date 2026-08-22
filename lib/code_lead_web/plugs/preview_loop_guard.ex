defmodule CodeLeadWeb.Plugs.PreviewLoopGuard do
  @moduledoc """
  Stops the path gateway serving the same preview page to a browser that
  is reloading itself in a tight loop, and explains why instead.

  The loop comes from a previewed app emitting root-absolute URLs that
  escape its `/preview/<task_id>` mount — see
  `CodeLeadWeb.PreviewProxy.LoopBreaker` for the mechanism. This plug
  only decides *what counts*; the counting lives there.

  Note what this is not: it never touches a proxied body. On a trip it
  **replaces** a response CodeLead was about to fetch with a page
  CodeLead authored — the same move `ErrorPages.wrong_gateway/1` and
  `not_running/1` already make. The no-body-rewriting contract of
  ADR-0008 (upheld by ADR-0011) is untouched.

  Sits last in the `:preview` pipeline, so the session is fetched and
  `RequirePreviewAccess` has already turned anonymous traffic away —
  nothing unauthenticated can reach, or fill, the breaker.
  """

  @behaviour Plug

  import Plug.Conn

  alias CodeLead.PreviewGateway
  alias CodeLeadWeb.PreviewProxy.ErrorPages
  alias CodeLeadWeb.PreviewProxy.LoopBreaker

  @bypass_param "_clp_loop_bypass"

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "GET", path_info: ["preview", task_id | rest]} = conn, opts) do
    breaker = Keyword.get(opts, :breaker, LoopBreaker)

    with {id, ""} <- Integer.parse(task_id),
         true <- LoopBreaker.enabled?(),
         true <- PreviewGateway.impl() != CodeLead.PreviewGateway.SubdomainProxy do
      guard(conn, id, rest, breaker)
    else
      _not_a_guarded_preview -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp guard(conn, id, rest, breaker) do
    cond do
      bypass?(conn) -> resume(conn, id, breaker)
      countable?(conn, rest) -> count(conn, id, breaker)
      true -> conn
    end
  end

  defp count(conn, id, breaker) do
    case LoopBreaker.record(key(conn, id), conn.request_path, breaker) do
      :tripped -> trip(conn, id)
      :ok -> conn
    end
  end

  # 200, not a 5xx: reverse proxies that intercept upstream errors
  # (nginx's `proxy_intercept_errors` and various PaaS edges) would
  # swap this page for their own — and the whole point is that it gets
  # read. No auto-refresh either; reloading is the symptom.
  defp trip(conn, id) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, ErrorPages.reload_loop(id, bypass_href(conn)))
    |> halt()
  end

  # Consume the bypass and bounce to the clean URL, so the param never
  # reaches upstream and cannot be carried around by a resumed loop.
  defp resume(conn, id, breaker) do
    LoopBreaker.pause(key(conn, id), breaker)

    conn
    |> put_resp_header("location", strip_bypass(conn))
    |> send_resp(302, "")
    |> halt()
  end

  defp countable?(conn, rest) do
    forwarded_path?(conn, rest) and document_navigation?(conn) and not user_reload?(conn)
  end

  # `/preview/42` is 302'd to `/preview/42/` by the controller before it
  # ever reaches the upstream; counting that leg would double-count
  # every bare-path navigation.
  defp forwarded_path?(conn, rest), do: rest != [] or String.ends_with?(conn.request_path, "/")

  # A non-`document` value is trusted as-is rather than falling through
  # to the `accept` sniff, so an XHR whose Accept happens to include
  # text/html cannot count. The fallback covers clients sending no
  # Sec-Fetch-Dest at all.
  defp document_navigation?(conn) do
    case get_req_header(conn, "sec-fetch-dest") do
      ["document"] -> true
      [_other] -> false
      [] -> conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))
    end
  end

  # A person reloading sends `max-age=0` (F5) or `no-cache` (hard
  # reload); the scripted `window.location = href` that drives this loop
  # sends neither. Erring here fails safe — we would miss a loop rather
  # than interrupt someone who is just refreshing.
  defp user_reload?(conn) do
    conn
    |> get_req_header("cache-control")
    |> Enum.any?(&(String.contains?(&1, "max-age=0") or String.contains?(&1, "no-cache")))
  end

  # Per login session rather than per IP: behind the reverse proxy that
  # fronts every real deployment, `remote_ip` is shared by everyone.
  # Hashed so a long-lived process holds no live session token.
  defp key(conn, id), do: {id, :erlang.phash2(get_session(conn, :user_token))}

  # Cheap string test first: this runs on every proxied request, assets
  # included, and only the rare bypass click is worth decoding for.
  defp bypass?(%Plug.Conn{query_string: query}) when is_binary(query),
    do: String.contains?(query, @bypass_param)

  defp bypass?(_conn), do: false

  defp bypass_href(conn), do: append_query(conn.request_path, put_bypass(conn))

  defp strip_bypass(conn) do
    conn = fetch_query_params(conn)
    append_query(conn.request_path, Map.delete(conn.query_params, @bypass_param))
  end

  defp put_bypass(conn) do
    conn = fetch_query_params(conn)
    Map.put(conn.query_params, @bypass_param, "1")
  end

  defp append_query(path, params) when map_size(params) == 0, do: path
  defp append_query(path, params), do: path <> "?" <> Plug.Conn.Query.encode(params)
end
