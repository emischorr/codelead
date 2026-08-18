defmodule CodeLead.PreviewGateway.Address do
  @moduledoc """
  Resolves the two addresses container-task previews depend on: the
  host interface the relay publishes on (`publish_ip/0`) and the
  address the in-app proxy dials (`upstream_host/0`).

  Convention over configuration: unset, both resolve to the same
  auto-detected default — loopback when the BEAM runs on the docker
  host (dev), the docker bridge gateway when the app itself runs in a
  container (the deployed compose stack, where loopback would land in
  the app container's own namespace and never reach a host-published
  port). `PREVIEW_PUBLISH_IP` / `PREVIEW_UPSTREAM_HOST` override the
  detection for exotic setups.

  Detection shells the docker CLI once and caches the outcome — success
  or fallback — in `:persistent_term`.
  """

  require Logger

  alias CodeLead.Executor.DockerCli

  @cache_key {__MODULE__, :auto_host}

  @doc """
  The host interface the relay publishes the preview port on.
  """
  @spec publish_ip() :: String.t()
  def publish_ip, do: resolve(:preview_publish_ip)

  @doc """
  The address the in-app preview proxy dials for container upstreams.
  """
  @spec upstream_host() :: String.t()
  def upstream_host, do: resolve(:preview_upstream_host)

  @doc """
  Clears the cached auto-detected address (tests).
  """
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp resolve(key) do
    case Application.get_env(:code_lead, key) do
      nil -> auto_host()
      configured -> configured
    end
  end

  defp auto_host do
    case :persistent_term.get(@cache_key, :unset) do
      :unset ->
        host = detect()
        :persistent_term.put(@cache_key, host)
        host

      host ->
        host
    end
  end

  defp detect do
    if containerized?(), do: bridge_gateway(), else: "127.0.0.1"
  end

  # Asked from the daemon itself so custom bridge subnets resolve too.
  # A failed detection falls back to loopback — previews won't work, but
  # the warning names the fix instead of a silent dead address.
  defp bridge_gateway do
    format = "{{(index .IPAM.Config 0).Gateway}}"

    with {:ok, output} <- DockerCli.run(["network", "inspect", "bridge", "-f", format]),
         gateway = String.trim(output),
         {:ok, _parsed} <- :inet.parse_address(String.to_charlist(gateway)) do
      gateway
    else
      failure ->
        Logger.warning(
          "could not auto-detect the docker bridge gateway (#{inspect(failure)}) — " <>
            "container-task previews will fail; set PREVIEW_PUBLISH_IP and " <>
            "PREVIEW_UPSTREAM_HOST, see docs/deployment.md"
        )

        "127.0.0.1"
    end
  end

  defp containerized? do
    case Application.get_env(:code_lead, :containerized?) do
      nil -> File.exists?("/.dockerenv")
      containerized -> containerized
    end
  end
end
