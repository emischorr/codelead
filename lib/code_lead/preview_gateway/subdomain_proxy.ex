defmodule CodeLead.PreviewGateway.SubdomainProxy do
  @moduledoc """
  Subdomain preview gateway: each task is previewed on its own origin,
  `http(s)://task-<id>.<PREVIEW_DOMAIN>/`. Requests still arrive at
  this same app — the operator's wildcard DNS and reverse-proxy rule
  point the subdomains here, and `CodeLeadWeb.Endpoint.call/2` diverts
  them by host into the preview pipeline before the router. A real
  origin per task means no base-path requirement and no cookie
  rewriting, which is the whole point: apps that break under
  path-prefix hosting (double-submit CSRF, hard-coded absolute paths)
  work here unchanged.

  Enabled by setting `PREVIEW_DOMAIN`; it then replaces `PathProxy`
  instance-wide (see `config/runtime.exs`). Upstream resolution is the
  shared `CodeLead.PreviewGateway.Upstream` — only the browser-facing
  URL differs between gateways.
  """

  @behaviour CodeLead.PreviewGateway

  alias CodeLead.PreviewGateway
  alias CodeLead.PreviewGateway.Upstream
  alias CodeLead.Tasks.Task

  @impl true
  def url_for(%Task{} = task) do
    with {:ok, _port} <- PreviewGateway.preview_port(task) do
      domain = Application.fetch_env!(:code_lead, :preview_domain)
      url = Application.get_env(:code_lead, :preview_url, [])
      scheme = Keyword.get(url, :scheme, "http")
      port = Keyword.get(url, :port)

      {:ok, "#{scheme}://task-#{task.id}.#{domain}#{port_suffix(scheme, port)}/"}
    end
  end

  @impl true
  def upstream_for(%Task{} = task), do: Upstream.resolve(task)

  defp port_suffix("http", 80), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix(_scheme, nil), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"
end
