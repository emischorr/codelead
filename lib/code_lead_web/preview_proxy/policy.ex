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
            strip_request_cookies: []

  @type t :: %__MODULE__{
          mount_path: String.t(),
          cookie_prefix: String.t() | nil,
          rewrite_location?: boolean(),
          strip_request_cookies: [String.t()]
        }

  @doc "The policy for the active gateway."
  @spec for_task(integer() | String.t()) :: t()
  def for_task(task_id) do
    case PreviewGateway.impl() do
      CodeLead.PreviewGateway.SubdomainProxy -> subdomain()
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
      strip_request_cookies: []
    }
  end

  @doc """
  Subdomain policy: the preview owns its origin, so nothing is rewritten;
  only the preview host's own session cookie stays out of the upstream.
  """
  @spec subdomain() :: t()
  def subdomain do
    %__MODULE__{
      mount_path: "",
      cookie_prefix: nil,
      rewrite_location?: false,
      strip_request_cookies: [@session_cookie]
    }
  end

  @doc "The session cookie name used on preview subdomain hosts."
  @spec session_cookie() :: String.t()
  def session_cookie, do: @session_cookie
end
