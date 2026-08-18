defmodule CodeLead.PreviewGateway.AddressTest do
  # async: false — swaps the :docker_cli config, preview config keys,
  # env vars the fake docker script reads, and the persistent_term cache.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodeLead.PreviewGateway.Address

  @fake_docker Path.expand("../../support/fake_docker.sh", __DIR__)
  @config_keys [:preview_publish_ip, :preview_upstream_host, :containerized?, :docker_cli]

  setup do
    original = for key <- @config_keys, do: {key, Application.get_env(:code_lead, key)}
    Address.reset_cache()

    on_exit(fn ->
      for {key, value} <- original do
        case value do
          nil -> Application.delete_env(:code_lead, key)
          value -> Application.put_env(:code_lead, key, value)
        end
      end

      System.delete_env("FAKE_DOCKER_BRIDGE_GATEWAY")
      Address.reset_cache()
    end)

    :ok
  end

  defp use_docker(scenario) do
    Application.put_env(:code_lead, :docker_cli, ["sh", @fake_docker, scenario])
  end

  test "configured values win over auto-detection" do
    Application.put_env(:code_lead, :containerized?, true)
    Application.put_env(:code_lead, :preview_publish_ip, "10.0.0.7")
    Application.put_env(:code_lead, :preview_upstream_host, "10.0.0.8")

    assert Address.publish_ip() == "10.0.0.7"
    assert Address.upstream_host() == "10.0.0.8"
  end

  test "unset on a host BEAM resolves to loopback" do
    Application.put_env(:code_lead, :containerized?, false)

    assert Address.publish_ip() == "127.0.0.1"
    assert Address.upstream_host() == "127.0.0.1"
  end

  test "unset in a containerized app resolves to the daemon's bridge gateway" do
    use_docker("running")
    Application.put_env(:code_lead, :containerized?, true)
    System.put_env("FAKE_DOCKER_BRIDGE_GATEWAY", "10.99.0.1")

    assert Address.publish_ip() == "10.99.0.1"
    assert Address.upstream_host() == "10.99.0.1"
  end

  test "detection runs once and is cached" do
    use_docker("running")
    Application.put_env(:code_lead, :containerized?, true)

    assert Address.publish_ip() == "172.17.0.1"

    # A later call must not shell docker again: point the CLI at a
    # failing scenario and expect the cached gateway regardless.
    use_docker("daemon_down")
    assert Address.upstream_host() == "172.17.0.1"
  end

  test "an unreachable daemon falls back to loopback with a warning" do
    use_docker("daemon_down")
    Application.put_env(:code_lead, :containerized?, true)

    log =
      capture_log(fn ->
        assert Address.publish_ip() == "127.0.0.1"
      end)

    assert log =~ "could not auto-detect the docker bridge gateway"
  end

  test "an unparsable gateway falls back to loopback with a warning" do
    use_docker("running")
    Application.put_env(:code_lead, :containerized?, true)
    System.put_env("FAKE_DOCKER_BRIDGE_GATEWAY", "not-an-ip")

    log =
      capture_log(fn ->
        assert Address.upstream_host() == "127.0.0.1"
      end)

    assert log =~ "could not auto-detect the docker bridge gateway"
  end
end
