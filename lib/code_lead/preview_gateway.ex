defmodule CodeLead.PreviewGateway do
  @moduledoc """
  Seam between "a task exposes an HTTP preview" and how the browser
  reaches it.

  The review contract is a URL: something in the task's execution
  context serves HTTP, and the Review tab links to it (previews open in
  their own browser tab). Implementations decide how that URL is routed
  — `PathProxy` (the zero-config default) proxies `/preview/:task_id/*`
  through the app itself; `SubdomainProxy` hands out per-task
  subdomains instead and takes over instance-wide when `PREVIEW_DOMAIN`
  is set. Exactly one gateway is active at a time.
  """

  alias CodeLead.Projects
  alias CodeLead.Tasks.Task

  @typedoc "Where the in-app proxy dials a task's preview server."
  @type upstream :: %{host: String.t(), port: :inet.port_number()}

  @doc """
  Browser-facing URL the preview opens at — a path under the app's own
  origin (`PathProxy`) or an absolute URL (`SubdomainProxy`). Callers
  must not assume a path.
  """
  @callback url_for(task :: Task.t()) ::
              {:ok, String.t()} | {:error, :no_preview_port | :unsupported}

  @doc """
  Host/port the in-app proxy should dial for this task's preview.
  """
  @callback upstream_for(task :: Task.t()) ::
              {:ok, upstream()} | {:error, :no_preview_port | :not_running | term()}

  @doc """
  The configured gateway implementation.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:code_lead, :preview_gateway, __MODULE__.PathProxy)

  @doc """
  The task's declared preview port — the repository's `preview_port`,
  the one field every gateway implementation keys on.
  """
  @spec preview_port(Task.t()) ::
          {:ok, :inet.port_number()} | {:error, :no_preview_port | :unsupported}
  def preview_port(%Task{target: :repo, repository_id: repository_id})
      when is_integer(repository_id) do
    case Projects.get_repository!(repository_id).preview_port do
      nil -> {:error, :no_preview_port}
      port -> {:ok, port}
    end
  end

  def preview_port(%Task{target: :repo}), do: {:error, :no_preview_port}
  def preview_port(%Task{}), do: {:error, :unsupported}

  @doc """
  Env vars injected into terminal and preview execs so serve commands
  can configure themselves: the base path and allowed origin, plus the
  declared port to bind (unique per repository across the instance).

  `app_origin` is the app's own external origin, pre-computed by the
  web-layer caller. It is the preview origin only under a path-mounted
  gateway; when `url_for/1` is absolute (subdomain gateway) the origin
  and base derive from that URL instead — the base path collapses to
  `""` because the preview owns its origin's root.
  """
  @spec preview_env(Task.t(), String.t()) :: [{String.t(), String.t()}]
  def preview_env(%Task{} = task, app_origin) do
    with {:ok, url} <- impl().url_for(task),
         {:ok, port} <- preview_port(task) do
      {origin, base} =
        case URI.parse(url) do
          %URI{host: nil} -> {app_origin, url}
          %URI{path: path} = uri -> {recompose_origin(uri), path || "/"}
        end

      [
        {"PREVIEW_BASE_PATH", String.trim_trailing(base, "/")},
        {"PREVIEW_ORIGIN", origin},
        {"PREVIEW_PORT", Integer.to_string(port)}
      ]
    else
      {:error, _reason} -> []
    end
  end

  defp recompose_origin(%URI{scheme: scheme, host: host, port: port}) do
    if port == URI.default_port(scheme) do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end
end
