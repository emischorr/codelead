defmodule CodeLead.PreviewGateway do
  @moduledoc """
  Seam between "a task exposes an HTTP preview" and how the browser
  reaches it.

  The review contract is a URL: something in the task's execution
  context serves HTTP, and the Review tab renders it. Implementations
  decide how that URL is routed — `PathProxy` (the only one today)
  proxies `/preview/:task_id/*` through the app itself; a future
  `SubdomainProxy` would hand out per-task subdomains instead.
  """

  alias CodeLead.Tasks.Task

  @typedoc "Where the in-app proxy dials a task's preview server."
  @type upstream :: %{host: String.t(), port: :inet.port_number()}

  @doc """
  Browser-facing URL (path or absolute) the Review tab should frame.
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
  Env vars injected into terminal (and later preview) execs so serve
  commands can configure a base path / allowed origins. The external
  origin is pre-computed by the web-layer caller.
  """
  @spec preview_env(Task.t(), String.t()) :: [{String.t(), String.t()}]
  def preview_env(%Task{} = task, origin) do
    case impl().url_for(task) do
      {:ok, base} ->
        [
          {"PREVIEW_BASE_PATH", String.trim_trailing(base, "/")},
          {"PREVIEW_ORIGIN", origin}
        ]

      {:error, _reason} ->
        []
    end
  end
end
