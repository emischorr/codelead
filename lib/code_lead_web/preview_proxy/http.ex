defmodule CodeLeadWeb.PreviewProxy.HTTP do
  @moduledoc """
  Plain-HTTP half of the preview proxy: forwards one request to the
  task's upstream and streams the response back chunked, so SSE and
  chunked dev-server responses flow through without buffering.

  Request bodies are buffered (preview traffic is forms/JSON, not
  uploads worth streaming); responses stream via Req's async body.
  """

  import Plug.Conn

  require Logger

  alias CodeLeadWeb.PreviewProxy.ErrorPages
  alias CodeLeadWeb.PreviewProxy.Headers

  @methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete,
    "OPTIONS" => :options,
    "HEAD" => :head
  }

  # No response body may accompany these; chunking them trips clients.
  @bodiless_statuses [204, 304]

  @doc """
  Forwards the request to `upstream` and streams the response into
  `conn`. `prefix` is the external `/preview/<task_id>` mount, used
  for header rewriting; `upstream_path` must carry the original
  (still percent-encoded) path and query.
  """
  @spec forward(Plug.Conn.t(), CodeLead.PreviewGateway.upstream(), String.t(), String.t()) ::
          Plug.Conn.t()
  def forward(conn, %{host: host, port: port} = upstream, prefix, upstream_path) do
    with {:ok, method} <- Map.fetch(@methods, conn.method),
         {:ok, body, conn} <- read_full_body(conn) do
      request =
        Req.new(
          method: method,
          url: "http://#{host}:#{port}#{upstream_path}",
          headers: Headers.request_headers(conn, upstream, prefix),
          # nil, not "" — Req silently turns a GET with a body into a POST.
          body: if(body == "", do: nil, else: body),
          raw: true,
          redirect: false,
          retry: false,
          compressed: false,
          receive_timeout: :infinity,
          connect_options: [timeout: 5_000],
          into: :self
        )

      case Req.request(request) do
        {:ok, response} ->
          stream_response(conn, response, prefix)

        {:error, transport} ->
          # Debug, not warning: the error page reloads every few seconds
          # while an upstream is down, so this fires in a steady loop.
          Logger.debug("preview proxy: connect to #{host}:#{port} failed: #{inspect(transport)}")

          not_running(conn, upstream)
      end
    else
      :error -> send_resp(conn, 405, "method not allowed")
      {:error, _body_read} -> send_resp(conn, 400, "bad request")
    end
  end

  defp stream_response(conn, response, prefix) do
    headers = Headers.response_headers(flatten_headers(response.headers), prefix)

    cond do
      response.status in @bodiless_statuses ->
        Req.cancel_async_response(response)

        conn
        |> merge_resp_headers(headers)
        |> send_resp(response.status, "")

      match?(%Req.Response.Async{}, response.body) ->
        conn
        |> merge_resp_headers(headers)
        |> send_chunked(response.status)
        |> stream_body(response)

      true ->
        conn
        |> merge_resp_headers(headers)
        |> send_resp(response.status, response.body)
    end
  end

  # A dead upstream mid-stream just truncates the body — the status is
  # long gone, so there is nothing better to tell the browser.
  defp stream_body(conn, response) do
    Enum.reduce_while(response.body, conn, fn chunk, conn ->
      case chunk(conn, chunk) do
        {:ok, conn} ->
          {:cont, conn}

        {:error, _closed} ->
          Req.cancel_async_response(response)
          {:halt, conn}
      end
    end)
  rescue
    _transport_error -> conn
  end

  defp not_running(conn, upstream) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(502, ErrorPages.not_running(upstream))
  end

  defp read_full_body(conn, acc \\ []) do
    case read_body(conn) do
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary([acc, chunk]), conn}
      {:more, chunk, conn} -> read_full_body(conn, [acc, chunk])
      {:error, reason} -> {:error, reason}
    end
  end

  defp flatten_headers(headers) when is_map(headers) do
    for {name, values} <- headers, value <- List.wrap(values), do: {name, value}
  end

  defp flatten_headers(headers) when is_list(headers), do: headers
end
