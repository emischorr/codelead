defmodule CodeLead.Executor.HarnessStagingTest do
  # async: false — swaps the :docker_cli / harness config and env vars.
  # No Repo involved. Staged runtimes persist in the test workspace
  # across tests, so every test uses its own unique version.
  use ExUnit.Case, async: false

  alias CodeLead.Executor.HarnessStaging
  alias CodeLead.Workspace

  @fake_docker Path.expand("../../support/fake_docker.sh", __DIR__)

  setup do
    original = Application.get_env(:code_lead, :docker_cli)
    original_version = Application.get_env(:code_lead, :harness_version)
    original_source = Application.get_env(:code_lead, :harness_source)
    original_user = Application.get_env(:code_lead, :container_user)
    log = Path.join(System.tmp_dir!(), "fake_docker_#{System.unique_integer([:positive])}.log")
    System.put_env("FAKE_DOCKER_LOG", log)

    on_exit(fn ->
      Application.put_env(:code_lead, :docker_cli, original)
      Application.put_env(:code_lead, :harness_version, original_version)
      Application.put_env(:code_lead, :harness_source, original_source)
      Application.put_env(:code_lead, :container_user, original_user)
      System.delete_env("FAKE_DOCKER_LOG")
      File.rm(log)
    end)

    %{log: log}
  end

  defp use_docker(scenario) do
    Application.put_env(:code_lead, :docker_cli, ["sh", @fake_docker, scenario])
  end

  defp use_version! do
    version = "0.0.#{System.unique_integer([:positive])}"
    Application.put_env(:code_lead, :harness_version, version)
    Application.put_env(:code_lead, :harness_source, nil)
    version
  end

  defp stage_runtime!(dir) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "claude-agent-acp"), "already-here")
    File.write!(Path.join(dir, "bun"), "a-bun")
  end

  defp log_lines(log) do
    case File.read(log) do
      {:ok, content} -> String.split(content, "\n", trim: true)
      {:error, _} -> []
    end
  end

  test "an already staged runtime short-circuits without touching docker", %{log: log} do
    use_docker("absent")
    version = use_version!()
    wrapper = Workspace.harness_binary(version, :glibc)
    stage_runtime!(Path.dirname(wrapper))

    assert HarnessStaging.ensure_staged(:glibc) == {:ok, wrapper}
    assert log_lines(log) == []
  end

  test "a stale compiled-binary layout is restaged", %{log: log} do
    use_docker("absent")
    version = use_version!()
    wrapper = Workspace.harness_binary(version, :glibc)

    # The previous generation staged a bare binary with no runtime.
    File.mkdir_p!(Path.dirname(wrapper))
    File.write!(wrapper, "old-compiled-binary")

    assert HarnessStaging.ensure_staged(:glibc) == {:ok, wrapper}
    assert File.read!(wrapper) == "fake-harness"
    assert File.exists?(Path.join(Path.dirname(wrapper), "bun"))
    assert [_staging_run] = log_lines(log)
  end

  test "copies a pre-staged flavor from a harness_source directory without docker", %{log: log} do
    use_docker("absent")
    version = use_version!()
    source_dir = Path.join(System.tmp_dir!(), "harness_src_#{System.unique_integer([:positive])}")
    stage_runtime!(Path.join(source_dir, "glibc"))
    File.write!(Path.join([source_dir, "glibc", "claude-agent-acp"]), "baked-glibc")
    on_exit(fn -> File.rm_rf(source_dir) end)
    Application.put_env(:code_lead, :harness_source, source_dir)

    wrapper = Workspace.harness_binary(version, :glibc)
    assert HarnessStaging.ensure_staged(:glibc) == {:ok, wrapper}
    assert File.read!(wrapper) == "baked-glibc"
    assert File.exists?(Path.join(Path.dirname(wrapper), "bun"))
    assert %{mode: mode} = File.stat!(wrapper)
    assert Bitwise.band(mode, 0o111) != 0
    assert log_lines(log) == []

    # Idempotent: the staged copy wins over a changed source.
    File.write!(Path.join([source_dir, "glibc", "claude-agent-acp"]), "changed")
    assert HarnessStaging.ensure_staged(:glibc) == {:ok, wrapper}
    assert File.read!(wrapper) == "baked-glibc"
  end

  test "a flavor missing from the source directory falls through to staging", %{log: log} do
    use_docker("absent")
    version = use_version!()
    source_dir = Path.join(System.tmp_dir!(), "harness_src_#{System.unique_integer([:positive])}")
    stage_runtime!(Path.join(source_dir, "glibc"))
    on_exit(fn -> File.rm_rf(source_dir) end)
    Application.put_env(:code_lead, :harness_source, source_dir)

    assert {:ok, wrapper} = HarnessStaging.ensure_staged(:musl)
    assert wrapper == Workspace.harness_binary(version, :musl)
    assert File.read!(wrapper) == "fake-harness"
    assert [run_line] = log_lines(log)
    assert run_line =~ "oven/bun:1-alpine"
  end

  test "stages each flavor via its matching bun image", %{log: log} do
    use_docker("absent")
    version = use_version!()

    assert {:ok, musl} = HarnessStaging.ensure_staged(:musl)
    assert {:ok, glibc} = HarnessStaging.ensure_staged(:glibc)

    assert musl == Workspace.harness_binary(version, :musl)
    assert glibc == Workspace.harness_binary(version, :glibc)
    assert musl != glibc
    assert File.read!(musl) == "fake-harness"
    assert File.exists?(Path.join(Path.dirname(glibc), "bun"))
    assert %{mode: mode} = File.stat!(glibc)
    assert Bitwise.band(mode, 0o111) != 0

    assert [musl_line, glibc_line] = log_lines(log)
    assert musl_line =~ "run --rm"
    assert musl_line =~ "-v #{Workspace.root()}:#{Workspace.root()}"
    assert musl_line =~ "-e OUT=#{Path.dirname(musl)}.tmp"
    assert musl_line =~ "oven/bun:1-alpine sh -c"
    assert glibc_line =~ "oven/bun:1 sh -c"
    refute musl_line =~ "--user"
  end

  test "a configured container user shapes the staging container", %{log: log} do
    use_docker("absent")
    use_version!()
    Application.put_env(:code_lead, :container_user, "1000:1000")

    assert {:ok, _wrapper} = HarnessStaging.ensure_staged(:glibc)

    assert [run_line] = log_lines(log)
    assert run_line =~ "--user 1000:1000"
    assert run_line =~ "-e HOME=/tmp"
  end

  test "a failed staging reports the docker output and stages nothing" do
    use_docker("build_fails")
    version = use_version!()

    assert {:error, {:harness_build_failed, output}} = HarnessStaging.ensure_staged(:glibc)
    assert output =~ "registry"
    refute File.exists?(Workspace.harness_binary(version, :glibc))
  end

  test "concurrent callers serialize on one staging", %{log: log} do
    use_docker("absent")
    use_version!()

    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> HarnessStaging.ensure_staged(:glibc) end) end)
      |> Task.await_many(:timer.seconds(30))

    assert Enum.all?(results, &match?({:ok, _path}, &1))
    assert [_one_staging] = Enum.filter(log_lines(log), &String.starts_with?(&1, "run "))
  end

  test "a cleared version is a clean error, not a crash" do
    use_docker("absent")
    Application.delete_env(:code_lead, :harness_version)

    assert {:error, {:harness_not_staged, detail}} = HarnessStaging.ensure_staged(:glibc)
    assert detail =~ "HARNESS_VERSION"
  end
end
