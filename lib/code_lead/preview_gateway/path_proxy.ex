defmodule CodeLead.PreviewGateway.PathProxy do
  @moduledoc """
  Path-prefix preview gateway: tasks are previewed at
  `/preview/:task_id/` on the app's own origin, reverse-proxied by
  `CodeLeadWeb.PreviewProxyController`.

  Upstream resolution by execution env:

    * `:local` — the dev server runs in the worktree on this node, so
      the upstream is `127.0.0.1:<preview_port>` (in a deployed stack
      "this node" is the app container, which is still correct).
    * `:container` — the task container publishes `preview_port` to an
      ephemeral host port at create time (`docker create -p`); we
      resolve it via `docker port` and dial
      `:preview_upstream_host` (loopback in dev, the docker bridge
      gateway in a deployed stack).
  """

  @behaviour CodeLead.PreviewGateway

  alias CodeLead.Executor.DockerCli
  alias CodeLead.Executor.DockerContainer
  alias CodeLead.Projects
  alias CodeLead.Tasks.Task

  @impl true
  def url_for(%Task{} = task) do
    with {:ok, _port} <- preview_port(task) do
      {:ok, "/preview/#{task.id}/"}
    end
  end

  @impl true
  def upstream_for(%Task{execution_env: :local} = task) do
    with {:ok, port} <- preview_port(task) do
      {:ok, %{host: "127.0.0.1", port: port}}
    end
  end

  def upstream_for(%Task{execution_env: :container} = task) do
    with {:ok, port} <- preview_port(task) do
      resolve_published_port(DockerContainer.container_name(task.id), port)
    end
  end

  defp preview_port(%Task{target: :repo, repository_id: repository_id})
       when is_integer(repository_id) do
    case Projects.get_repository!(repository_id).preview_port do
      nil -> {:error, :no_preview_port}
      port -> {:ok, port}
    end
  end

  defp preview_port(%Task{target: :repo}), do: {:error, :no_preview_port}
  defp preview_port(%Task{}), do: {:error, :unsupported}

  # `docker port` prints one line per bound interface, e.g.
  #   127.0.0.1:55001
  #   [::1]:55002
  # We publish on a single IPv4 address, so take the first IPv4 line's
  # host port. The IP itself is *not* dialed — the reachable address is
  # deployment-specific (`:preview_upstream_host`).
  defp resolve_published_port(container, port) do
    case DockerCli.run(["port", container, "#{port}/tcp"]) do
      {:ok, out} ->
        case published_host_port(out) do
          nil -> {:error, :not_running}
          host_port -> {:ok, %{host: upstream_host(), port: host_port}}
        end

      {:error, _docker} ->
        {:error, :not_running}
    end
  end

  defp published_host_port(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "["))
    |> Enum.find_value(fn line ->
      with [_ip, port_str] <- String.split(line, ":"),
           {host_port, ""} <- Integer.parse(port_str) do
        host_port
      else
        _no_match -> nil
      end
    end)
  end

  defp upstream_host do
    Application.get_env(:code_lead, :preview_upstream_host, "127.0.0.1")
  end
end
