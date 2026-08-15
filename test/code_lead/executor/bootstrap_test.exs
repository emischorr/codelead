defmodule CodeLead.Executor.DockerContainer.BootstrapTest do
  # async: false — swaps the :docker_cli config and env vars.
  use CodeLead.DataCase, async: false

  alias CodeLead.Executor.DockerContainer.Bootstrap
  alias CodeLead.Workspace

  @fake_docker Path.expand("../../support/fake_docker.sh", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :docker_cli)
    original_version = Application.get_env(:code_lead, :harness_version)
    original_source = Application.get_env(:code_lead, :harness_source)
    log = Path.join(System.tmp_dir!(), "fake_docker_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_DOCKER_LOG", log)

    on_exit(fn ->
      Application.put_env(:code_lead, :docker_cli, original)
      Application.put_env(:code_lead, :harness_version, original_version)
      Application.put_env(:code_lead, :harness_source, original_source)
      System.delete_env("FAKE_DOCKER_LOG")
      File.rm(log)
    end)

    %{log: log}
  end

  defp use_docker(scenario) do
    Application.put_env(:code_lead, :docker_cli, ["sh", @fake_docker, scenario])
  end

  defp log_lines(log) do
    case File.read(log) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _} -> []
    end
  end

  defp with_source! do
    unique = System.unique_integer([:positive])
    version = "0.0.#{unique}"
    source_dir = Path.join(System.tmp_dir!(), "harness_source_#{unique}")
    glibc = Path.join([source_dir, "glibc", "claude-agent-acp"])
    File.mkdir_p!(Path.dirname(glibc))
    File.write!(glibc, "binary-bytes")
    File.write!(Path.join([source_dir, "glibc", "bun"]), "a-bun")
    on_exit(fn -> File.rm_rf(source_dir) end)
    Application.put_env(:code_lead, :harness_version, version)
    Application.put_env(:code_lead, :harness_source, source_dir)
    {version, glibc}
  end

  describe "harness staging" do
    test "stages the baked flavors, deferring absent ones without building", %{log: log} do
      use_docker("absent")
      {version, _glibc_source} = with_source!()

      assert Bootstrap.run() == :ok

      target = Workspace.harness_binary(version, :glibc)
      assert File.read!(target) == "binary-bytes"
      assert %{mode: mode} = File.stat!(target)
      # 0o755 within whatever type bits the OS adds
      assert Bitwise.band(mode, 0o111) != 0

      # No musl binary was baked: deferred, and no in-docker build ran.
      refute File.exists?(Workspace.harness_binary(version, :musl))
      refute Enum.any?(log_lines(log), &String.starts_with?(&1, "run "))
    end

    test "is idempotent — an already staged binary is left alone" do
      use_docker("absent")
      {version, glibc_source} = with_source!()

      assert Bootstrap.run() == :ok
      File.write!(glibc_source, "changed-bytes")
      assert Bootstrap.run() == :ok

      assert File.read!(Workspace.harness_binary(version, :glibc)) == "binary-bytes"
    end

    test "skips without a version, defers without a source — never builds at boot", %{log: log} do
      use_docker("absent")
      version = "0.0.#{System.unique_integer([:positive])}"

      # No version configured: nothing to stage.
      Application.delete_env(:code_lead, :harness_version)
      assert Bootstrap.run() == :ok
      refute File.exists?(Workspace.harness_binary(version, :glibc))

      # Version set but no baked source: defer to the lazy in-docker
      # build — boot itself must not trigger it.
      Application.put_env(:code_lead, :harness_version, version)
      Application.put_env(:code_lead, :harness_source, "/definitely/not/here")
      assert Bootstrap.run() == :ok
      refute File.exists?(Workspace.harness_binary(version, :glibc))
      refute Enum.any?(log_lines(log), &String.starts_with?(&1, "run "))
    end
  end

  describe "orphan reaping" do
    test "removes labeled containers whose tasks are not running", %{log: log} do
      use_docker("orphans")

      assert Bootstrap.run() == :ok

      lines = log |> File.read!() |> String.split("\n", trim: true)
      assert "rm -f abc123" in lines
      assert "rm -f def456" in lines
    end

    test "no-ops when the docker CLI is missing" do
      Application.put_env(:code_lead, :docker_cli, ["definitely-not-docker-xyz"])
      assert Bootstrap.run() == :ok
    end

    test "no-ops when the daemon is unreachable", %{log: log} do
      use_docker("daemon_down")
      assert Bootstrap.run() == :ok
      refute log |> File.read!() |> String.contains?("rm -f")
    end
  end
end
