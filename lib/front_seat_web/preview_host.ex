defmodule FrontSeatWeb.PreviewHost do
  @moduledoc """
  Request pipeline for subdomain previews. When the subdomain gateway
  is active (`PREVIEW_DOMAIN` set), `FrontSeatWeb.Endpoint.call/2` hands
  every request for a `task-<id>.<PREVIEW_DOMAIN>` host here instead of
  the normal endpoint pipeline — proxied traffic must not meet
  FrontSeat's sockets, static files, or body parsers.

  The pipeline is deliberately small: request id + telemetry (logging
  parity with the path gateway), a session under the preview host's own
  cookie name, the token-handshake auth gate
  (`FrontSeatWeb.PreviewHost.Auth`), then the shared
  `FrontSeatWeb.PreviewProxy.Forwarder` with the subdomain rewrite
  policy — no cookie namespacing, no `Location` rewriting.

  Hosts under the wildcard that don't parse as `task-<integer>` (the
  apex, arbitrary labels) fall through to the app itself.
  """

  import Plug.Conn

  alias FrontSeat.Tasks
  alias FrontSeat.PreviewGateway
  alias FrontSeatWeb.PreviewHost.Auth
  alias FrontSeatWeb.PreviewProxy.ErrorPages
  alias FrontSeatWeb.PreviewProxy.Forwarder
  alias FrontSeatWeb.PreviewProxy.Policy

  @doc """
  The task id when `host` is a preview subdomain of the configured
  `PREVIEW_DOMAIN`; nil otherwise (including whenever the subdomain
  gateway is off).
  """
  @spec match(String.t() | nil) :: integer() | nil
  def match(host) do
    case Application.get_env(:front_seat, :preview_domain) do
      nil -> nil
      domain -> parse_task_host(String.downcase(host || ""), String.downcase(domain))
    end
  end

  @doc """
  Runs the preview-host pipeline for a matched task id.
  """
  @spec call(Plug.Conn.t(), integer()) :: Plug.Conn.t()
  def call(conn, task_id) do
    conn =
      conn
      |> Plug.RequestId.call(Plug.RequestId.init([]))
      |> Plug.Telemetry.call(Plug.Telemetry.init(event_prefix: [:phoenix, :endpoint]))
      |> Plug.Session.call(session_config())
      |> fetch_session()
      |> Auth.call(task_id)

    if conn.halted do
      conn
    else
      dispatch(conn, task_id)
    end
  end

  defp parse_task_host(host, domain) do
    suffix = "." <> domain

    with true <- String.ends_with?(host, suffix),
         label = binary_part(host, 0, byte_size(host) - byte_size(suffix)),
         false <- String.contains?(label, "."),
         "task-" <> id_str <- label,
         {task_id, ""} <- Integer.parse(id_str) do
      task_id
    else
      _no_match -> nil
    end
  end

  defp dispatch(conn, task_id) do
    with %Tasks.Task{} = task <- Tasks.get_task(task_id),
         {:ok, _url} <- PreviewGateway.impl().url_for(task) do
      Forwarder.forward(conn, task, Policy.for_task(task.id))
    else
      nil -> Forwarder.error_page(conn, 404, ErrorPages.not_found())
      {:error, :no_preview_port} -> Forwarder.error_page(conn, 404, ErrorPages.no_port())
      {:error, :unsupported} -> Forwarder.error_page(conn, 404, ErrorPages.not_found())
    end
  end

  # The endpoint's session store and salts under the preview host's own
  # cookie name: a previewed FrontSeat (dogfooding) writes its own
  # `_front_seat_key` through the un-namespacing proxy, which must never
  # clobber the auth marker. The name is reserved — the subdomain policy
  # strips it from upstream-bound cookie headers.
  defp session_config do
    FrontSeatWeb.Endpoint.session_options()
    |> Keyword.put(:key, Policy.session_cookie())
    |> Plug.Session.init()
  end
end
