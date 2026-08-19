defmodule CodeLead.PreviewGateway.Upstream do
  @moduledoc """
  Upstream resolution shared by every preview gateway — where the
  gateways differ is the browser-facing URL, not where the dev server
  actually listens. Resolution by execution env:

    * `:local` — the dev server runs in the worktree on this node, so
      the upstream is `127.0.0.1:<preview_port>` (in a deployed stack
      "this node" is the app container, which is still correct).
    * `:container` — a relay sidecar (`CodeLead.PreviewGateway.Relay`)
      joins the task container's network and publishes `preview_port`
      to an ephemeral host port; we dial that port at the upstream
      address `CodeLead.PreviewGateway.Address` resolves (loopback on a
      host BEAM, the docker bridge gateway in a deployed stack).
  """

  require Logger

  alias CodeLead.Executor.Devcontainer
  alias CodeLead.PreviewGateway
  alias CodeLead.PreviewGateway.Address
  alias CodeLead.PreviewGateway.Relay
  alias CodeLead.Tasks.Task

  @spec resolve(Task.t()) ::
          {:ok, PreviewGateway.upstream()}
          | {:error, :no_preview_port | :unsupported | :not_running}
  def resolve(%Task{execution_env: :local} = task) do
    with {:ok, port} <- preview_port(task) do
      {:ok, %{host: "127.0.0.1", port: port}}
    end
  end

  def resolve(%Task{execution_env: :container} = task) do
    with {:ok, port} <- preview_port(task),
         {:ok, container_id} <- Devcontainer.container_for_task(task.id),
         {:ok, host_port} <- Relay.ensure(task.id, container_id, port) do
      {:ok, %{host: upstream_host(), port: host_port}}
    else
      {:error, :no_preview_port} = error ->
        error

      {:error, :unsupported} = error ->
        error

      # Whatever went wrong (environment gone or stopped, daemon down,
      # relay image unpullable), the honest answer to the proxy is the
      # same branded "not running" page — but the log names the reason.
      stopped_absent_or_error ->
        log_unavailable(task.id, stopped_absent_or_error)
        {:error, :not_running}
    end
  end

  defp preview_port(%Task{} = task), do: PreviewGateway.preview_port(task)

  defp upstream_host, do: Address.upstream_host()

  # `:absent`/`{:stopped, _}` are ordinary lifecycle states (the task
  # container was torn down or exited) and this path runs on every
  # proxied request, so they stay at debug; anything else is a docker or
  # relay failure worth a warning.
  defp log_unavailable(task_id, reason) do
    message = "preview upstream unavailable for task #{task_id}: #{inspect(reason)}"

    case reason do
      :absent -> Logger.debug(message)
      {:stopped, _container} -> Logger.debug(message)
      _docker_or_relay_error -> Logger.warning(message)
    end
  end
end
