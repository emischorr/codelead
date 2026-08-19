defmodule CodeLead.PreviewGateway.DomainCheck do
  @moduledoc """
  Boot-time sanity check for the subdomain preview gateway: preview
  cookies (the auth-handshake session and everything the previewed apps
  set) are first-party only while `PREVIEW_DOMAIN` shares its
  registrable domain with `PHX_HOST` — `preview.example.com` next to
  `codelead.example.com`. A foreign domain makes them third-party, which
  browsers increasingly block, so the handshake would silently fail;
  that configuration is unsupported and gets a loud warning instead of
  engineering (`Partitioned`, `SameSite=None`) around it.

  The registrable domain is approximated as the last two labels — no
  public-suffix list, so multi-label suffixes (`co.uk`) can slip through
  unwarned. It is only a warning; false negatives are tolerable.
  """

  require Logger

  @doc """
  Logs a prominent warning when the configured preview domain is not
  same-site with the app host. Never raises. Reads config itself.
  """
  @spec warn_on_cross_site() :: :ok
  def warn_on_cross_site do
    preview_domain = Application.get_env(:code_lead, :preview_domain)

    phx_host =
      :code_lead
      |> Application.get_env(CodeLeadWeb.Endpoint, [])
      |> Keyword.get(:url, [])
      |> Keyword.get(:host)

    warn_on_cross_site(preview_domain, phx_host)
  end

  @doc false
  @spec warn_on_cross_site(String.t() | nil, String.t() | nil) :: :ok
  def warn_on_cross_site(preview_domain, phx_host) do
    if cross_site?(preview_domain, phx_host) do
      Logger.warning("""
      PREVIEW_DOMAIN (#{preview_domain}) does not share a registrable domain \
      with PHX_HOST (#{phx_host}). Preview cookies will be third-party and \
      the preview auth handshake will likely be blocked by browsers — this \
      configuration is unsupported. Use a subdomain of the app's own site, \
      e.g. PREVIEW_DOMAIN=preview.#{registrable(phx_host)}.\
      """)
    end

    :ok
  end

  defp cross_site?(preview_domain, phx_host)
       when is_binary(preview_domain) and is_binary(phx_host) do
    not (exempt?(preview_domain) or exempt?(phx_host)) and
      registrable(preview_domain) != registrable(phx_host)
  end

  defp cross_site?(_preview_domain, _phx_host), do: false

  # localhost, *.localhost and IP literals never carry cross-site cookie
  # semantics worth warning about (dev and LAN setups).
  defp exempt?(host) do
    down = String.downcase(host)

    down == "localhost" or String.ends_with?(down, ".localhost") or ip_literal?(down)
  end

  defp ip_literal?(host) do
    match?({:ok, _ip}, :inet.parse_address(String.to_charlist(host)))
  end

  defp registrable(host) do
    host
    |> String.downcase()
    |> String.split(".")
    |> Enum.take(-2)
    |> Enum.join(".")
  end
end
