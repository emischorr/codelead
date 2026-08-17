defmodule CodeLead.PreviewGateway.Relay do
  @moduledoc """
  Per-task preview relay: a small forwarder container
  (`codelead-preview-<task_id>`) that joins the task container's
  network and publishes the declared preview port on an ephemeral host
  port, so the proxy reaches the dev server without the task container
  publishing anything at create time.

  Relays are cattle like task containers: identity is the deterministic
  name plus `codelead.*` labels, and the forward target (publish ip,
  task container ip, preview port) is recorded in a label. Any drift —
  the task container recreated with a new ip, a changed preview port,
  a changed `PREVIEW_PUBLISH_IP` — heals by recreating the relay, which
  is safe at any moment because no agent exec runs inside it.
  """

  alias CodeLead.Executor.DockerCli

  @doc """
  Ensures a relay forwarding to `task_container`'s preview port and
  returns the published host port.
  """
  @spec ensure(pos_integer(), String.t(), :inet.port_number()) ::
          {:ok, :inet.port_number()} | {:error, term()}
  def ensure(task_id, task_container, preview_port) do
    with {:ok, network, ip} <- task_endpoint(task_container) do
      ensure_relay(task_id, network, ip, preview_port)
    end
  end

  @doc """
  Removes the task's relay container, if any.
  """
  @spec remove(pos_integer()) :: :ok
  def remove(task_id) do
    _ = DockerCli.run(["rm", "-f", relay_name(task_id)])
    :ok
  end

  @doc """
  The deterministic relay container name for a task.
  """
  @spec relay_name(pos_integer()) :: String.t()
  def relay_name(task_id), do: "codelead-preview-#{task_id}"

  defp ensure_relay(task_id, network, ip, preview_port) do
    name = relay_name(task_id)
    target = "#{publish_ip()}|#{ip}:#{preview_port}"

    case relay_state(name) do
      {:running, ^target} ->
        case published_port(name, preview_port) do
          {:ok, host_port} -> {:ok, host_port}
          :none -> recreate(name, task_id, network, ip, preview_port)
        end

      :absent ->
        create(name, task_id, network, ip, preview_port)

      _stopped_or_drifted ->
        recreate(name, task_id, network, ip, preview_port)
    end
  end

  # The task container's first attached network and its ip on it — the
  # relay joins that network and forwards by ip (the default bridge has
  # no DNS, so container names are not resolvable there).
  defp task_endpoint(task_container) do
    case DockerCli.run(["inspect", "-f", "{{json .NetworkSettings.Networks}}", task_container]) do
      {:ok, output} ->
        with {:ok, %{} = networks} <- output |> String.trim() |> Jason.decode(),
             {network, ip} <- first_endpoint(networks) do
          {:ok, network, ip}
        else
          _absent_or_no_ip -> {:error, :not_running}
        end

      {:error, _docker_or_missing_cli} ->
        {:error, :not_running}
    end
  end

  defp first_endpoint(networks) do
    Enum.find_value(networks, fn
      {network, %{"IPAddress" => ip}} when is_binary(ip) and ip != "" -> {network, ip}
      _no_address -> nil
    end)
  end

  defp relay_state(name) do
    format = "{{.State.Running}}|{{index .Config.Labels \"codelead.preview_target\"}}"

    case DockerCli.run(["inspect", "-f", format, name]) do
      {:ok, output} ->
        case output |> String.trim() |> String.split("|", parts: 2) do
          ["true", target] -> {:running, target}
          [_not_running, target] -> {:stopped, target}
        end

      {:error, _docker_or_missing_cli} ->
        :absent
    end
  end

  defp recreate(name, task_id, network, ip, preview_port) do
    remove(task_id)
    create(name, task_id, network, ip, preview_port)
  end

  defp create(name, task_id, network, ip, preview_port) do
    target = "#{publish_ip()}|#{ip}:#{preview_port}"

    args =
      ["run", "-d", "--name", name] ++
        [
          "--label",
          "codelead.managed=true",
          "--label",
          "codelead.task_id=#{task_id}",
          "--label",
          "codelead.preview_relay=true",
          "--label",
          "codelead.preview_target=#{target}"
        ] ++
        ["--network", network, "-p", "#{publish_ip()}:0:#{preview_port}"] ++
        [relay_image()] ++
        ["tcp-listen:#{preview_port},fork,reuseaddr", "tcp:#{ip}:#{preview_port}"]

    with {:ok, _output} <- DockerCli.run(args),
         {:ok, host_port} <- published_result(name, preview_port) do
      {:ok, host_port}
    else
      {:error, _reason} = error -> error
    end
  end

  defp published_result(name, preview_port) do
    case published_port(name, preview_port) do
      {:ok, host_port} -> {:ok, host_port}
      :none -> {:error, :not_running}
    end
  end

  # `docker port` prints one line per bound interface, e.g.
  #   127.0.0.1:55001
  #   [::1]:55002
  # We publish on a single IPv4 address, so take the first IPv4 line's
  # host port. The ip itself is *not* dialed — the reachable address is
  # deployment-specific (`:preview_upstream_host`).
  defp published_port(name, preview_port) do
    case DockerCli.run(["port", name, "#{preview_port}/tcp"]) do
      {:ok, output} ->
        case published_host_port(output) do
          nil -> :none
          host_port -> {:ok, host_port}
        end

      {:error, _docker_or_missing_cli} ->
        :none
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

  defp publish_ip do
    Application.get_env(:code_lead, :preview_publish_ip, "127.0.0.1")
  end

  defp relay_image do
    Application.get_env(:code_lead, :preview_relay_image, "alpine/socat")
  end
end
