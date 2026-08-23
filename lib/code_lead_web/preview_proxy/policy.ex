defmodule CodeLeadWeb.PreviewProxy.Policy do
  @moduledoc """
  Per-task rewrite policy for the preview proxy — the knobs that differ
  between the two gateways. `PathProxy` previews share CodeLead's origin
  under `/preview/<id>`, so they need cookie namespacing and `Location`
  re-prefixing; `SubdomainProxy` previews own a real origin, so both
  retire and only the preview-host session cookie is withheld from the
  upstream. The forwarding plumbing itself is gateway-agnostic.
  """

  alias CodeLead.PreviewGateway

  @cookie_namespace "_clp"
  @session_cookie "_clp_session"

  defstruct mount_path: "",
            cookie_prefix: nil,
            rewrite_location?: false,
            strip_request_cookies: [],
            stale_prefix: nil

  @type t :: %__MODULE__{
          mount_path: String.t(),
          cookie_prefix: String.t() | nil,
          rewrite_location?: boolean(),
          strip_request_cookies: [String.t()],
          stale_prefix: String.t() | nil
        }

  @doc "The policy for the active gateway."
  @spec for_task(integer() | String.t()) :: t()
  def for_task(task_id) do
    case PreviewGateway.impl() do
      CodeLead.PreviewGateway.SubdomainProxy -> subdomain(task_id)
      _path_proxy_or_test_stub -> path(task_id)
    end
  end

  @doc "Path-prefix policy: mount under `/preview/<id>`, namespace cookies."
  @spec path(integer() | String.t()) :: t()
  def path(task_id) do
    %__MODULE__{
      mount_path: "/preview/#{task_id}",
      cookie_prefix: "#{@cookie_namespace}#{task_id}_",
      rewrite_location?: true,
      strip_request_cookies: [],
      stale_prefix: nil
    }
  end

  @doc """
  Subdomain policy: the preview owns its origin, so nothing is rewritten;
  only the preview host's own session cookie stays out of the upstream.

  `stale_prefix` is the one thing this gateway still watches for — a
  dev server started while the path gateway was active keeps emitting
  `/preview/<id>/…` URLs, and the 404s they earn here are otherwise
  indistinguishable from a genuinely missing route.
  """
  @spec subdomain(integer() | String.t()) :: t()
  def subdomain(task_id) do
    %__MODULE__{
      mount_path: "",
      cookie_prefix: nil,
      rewrite_location?: false,
      strip_request_cookies: [@session_cookie],
      stale_prefix: "/preview/#{task_id}/"
    }
  end

  @doc "The session cookie name used on preview subdomain hosts."
  @spec session_cookie() :: String.t()
  def session_cookie, do: @session_cookie
end
