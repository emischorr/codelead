defmodule CodeLead.PreviewUpstreamPlug do
  @moduledoc """
  In-test upstream for the preview proxy: a tiny plug served by a real
  Bandit listener on an ephemeral port, echoing back whatever the proxy
  forwarded so tests can assert on pass-through behavior.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["info"]} = conn, _opts) do
    headers = Enum.map_join(conn.req_headers, "\n", fn {name, value} -> "#{name}: #{value}" end)

    send_resp(conn, 200, "#{conn.method} #{conn.request_path}?#{conn.query_string}\n#{headers}")
  end

  def call(%Plug.Conn{path_info: ["echo"]} = conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    send_resp(conn, 200, body)
  end

  def call(%Plug.Conn{path_info: ["sse"]} = conn, _opts) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "chunk1")
    {:ok, conn} = chunk(conn, "chunk2")
    conn
  end

  def call(%Plug.Conn{path_info: ["redirect"]} = conn, _opts) do
    conn
    |> put_resp_header("location", "/after")
    |> send_resp(302, "")
  end

  def call(%Plug.Conn{path_info: ["nocontent"]} = conn, _opts) do
    send_resp(conn, 204, "")
  end

  def call(%Plug.Conn{path_info: ["hop"]} = conn, _opts) do
    conn
    |> put_resp_header("keep-alive", "timeout=5")
    |> put_resp_header("x-upstream", "yes")
    |> send_resp(200, "hop")
  end

  def call(%Plug.Conn{path_info: ["setcookie"]} = conn, _opts) do
    conn
    |> put_resp_cookie("sid", "abc", path: "/", http_only: true)
    |> put_resp_cookie("theme", "dark", path: "/admin")
    |> send_resp(200, "cookies")
  end

  # The reported bug: an upstream CodeLead setting the host's own
  # session cookie name on the shared origin.
  def call(%Plug.Conn{path_info: ["clobber"]} = conn, _opts) do
    conn
    |> put_resp_cookie("_code_lead_key", "junk", path: "/")
    |> send_resp(200, "clobber")
  end

  def call(%Plug.Conn{path_info: ["fancycookie"]} = conn, _opts) do
    conn
    |> put_resp_header(
      "set-cookie",
      "sid=abc; Path=/; Domain=example.com; Secure; SameSite=None; HttpOnly"
    )
    |> send_resp(200, "fancy")
  end

  # An app that knows nothing about the path gateway's mount — exactly
  # what a dev server carrying a stale PREVIEW_BASE_PATH earns for its
  # asset URLs under the subdomain gateway.
  def call(%Plug.Conn{path_info: ["preview", _task_id, "missing"]} = conn, _opts) do
    send_resp(conn, 404, "upstream 404")
  end

  def call(conn, _opts) do
    send_resp(conn, 200, "fallback #{conn.request_path}")
  end
end
