defmodule CodeLead.Executor.HarnessStaging do
  @moduledoc """
  Serializes staging of the container harness onto the workspace volume,
  per libc flavor. The staged harness is a *runtime directory*, not a
  compiled binary: the flavor-matched `bun` runtime, a real
  `node_modules` tree of the adapter, and a `sh` wrapper at the exec
  path — because the Claude Agent SDK resolves modules and its native
  CLI dynamically at runtime, which a `bun build --compile` virtual
  filesystem cannot satisfy (ADR-0007). Flavors exist because both the
  bun runtime and the SDK's native CLI are libc-specific (ADR-0006);
  installing inside the flavor-matched bun image selects both
  correctly. Being a GenServer is the point: concurrent callers queue
  behind the one staging instead of racing it.
  """

  use GenServer

  require Logger

  alias CodeLead.Executor.DockerCli
  alias CodeLead.Executor.WorkspaceMount
  alias CodeLead.Workspace

  @build_images %{musl: "oven/bun:1-alpine", glibc: "oven/bun:1"}
  @call_timeout :timer.minutes(10)

  @type flavor :: :musl | :glibc

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  The staged harness wrapper's path for a libc flavor, staging the
  runtime directory first if needed. The first call per flavor on a
  fresh instance may block for minutes while the runtime is staged.
  """
  @spec ensure_staged(flavor()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_staged(flavor) when flavor in [:musl, :glibc] do
    GenServer.call(__MODULE__, {:ensure_staged, flavor}, @call_timeout)
  end

  # Stateless: config and filesystem are re-read on every call.
  @impl GenServer
  def init(nil), do: {:ok, nil}

  @impl GenServer
  def handle_call({:ensure_staged, flavor}, _from, state) do
    {:reply, do_ensure_staged(flavor), state}
  end

  defp do_ensure_staged(flavor) do
    case Application.get_env(:code_lead, :harness_version) do
      nil ->
        {:error, {:harness_not_staged, "HARNESS_VERSION is not configured"}}

      version ->
        wrapper = Workspace.harness_binary(version, flavor)
        target = Path.dirname(wrapper)
        source = source_dir(flavor)

        cond do
          staged_complete?(target) -> {:ok, wrapper}
          is_binary(source) and staged_complete?(source) -> copy(source, target, wrapper)
          true -> stage_via_docker(version, flavor, target, wrapper)
        end
    end
  end

  # Wrapper + runtime present. Also invalidates the layout of an
  # earlier CodeLead generation that staged a bare compiled binary —
  # no `bun` sibling means restage.
  defp staged_complete?(dir) do
    File.exists?(Path.join(dir, "claude-agent-acp")) and File.exists?(Path.join(dir, "bun"))
  end

  # HARNESS_SOURCE is a directory holding pre-staged <flavor>/ runtime
  # dirs — the air-gapped escape hatch.
  defp source_dir(flavor) do
    case Application.get_env(:code_lead, :harness_source) do
      nil -> nil
      dir -> Path.join(dir, Atom.to_string(flavor))
    end
  end

  # Copy-then-rename so a concurrent reader never observes a
  # half-written runtime.
  defp copy(source, target, wrapper) do
    tmp = "#{target}.tmp.#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.dirname(target))
    File.cp_r!(source, tmp)
    File.chmod!(Path.join(tmp, "claude-agent-acp"), 0o755)
    File.chmod!(Path.join(tmp, "bun"), 0o755)
    File.rm_rf!(target)
    File.rename!(tmp, target)
    Logger.info("staged container harness at #{wrapper}")
    {:ok, wrapper}
  rescue
    error -> {:error, {:harness_not_staged, Exception.message(error)}}
  end

  defp stage_via_docker(version, flavor, target, wrapper) do
    # Host-created parent, so the rename below works whatever user the
    # build container wrote the output as.
    File.mkdir_p!(Path.dirname(target))
    out = "#{target}.tmp.#{System.unique_integer([:positive])}"
    image = Map.fetch!(@build_images, flavor)

    Logger.info(
      "staging container harness #{version} (#{flavor}) via #{image} — " <>
        "the first container run per libc flavor takes a few minutes"
    )

    args =
      ["run", "--rm"] ++
        WorkspaceMount.flags() ++
        ["-e", "OUT=#{out}"] ++
        build_user_flags() ++
        [image, "sh", "-c", stage_script(version)]

    case DockerCli.run(args) do
      {:ok, _output} ->
        finalize(out, target, wrapper)

      {:error, {:docker, _status, output}} ->
        _ = File.rm_rf(out)
        {:error, {:harness_build_failed, trim_output(output)}}

      {:error, :docker_cli_not_found} = error ->
        error
    end
  end

  # The install runs container-local under /tmp/build (writable for any
  # --user) and lands on the mount as one `cp -a`; the wrapper and
  # chmod happen in-container because the output may land root-owned on
  # a native-Linux host. OUT travels as a discrete `-e` flag rather
  # than only inside this script so the test fake can find it by
  # scanning argv. The wrapper execs the staged bun against the
  # adapter's real entry — everything resolves on real disk, which is
  # the entire point (ADR-0007).
  defp stage_script(version) do
    ~s(set -e; mkdir -p /tmp/build && cd /tmp/build && echo '{}' > package.json && ) <>
      "bun add @agentclientprotocol/claude-agent-acp@#{version} && " <>
      ~s(mkdir -p "$OUT" && cp -a node_modules package.json "$OUT/" && ) <>
      ~s(cp /usr/local/bin/bun "$OUT/bun" && ) <>
      ~s[printf '%s\\n' '#!/bin/sh' 'DIR="$(cd "$(dirname "$0")" && pwd)"' ] <>
      ~s['exec "$DIR/bun" "$DIR/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js" "$@"' ] <>
      ~s(> "$OUT/claude-agent-acp" && chmod 755 "$OUT/claude-agent-acp" "$OUT/bun")
  end

  # Match the volume owner where configured (prod); bun needs a
  # writable HOME for its install cache as that uid.
  defp build_user_flags do
    case Application.get_env(:code_lead, :container_user) do
      nil -> []
      user -> ["--user", user, "-e", "HOME=/tmp"]
    end
  end

  defp finalize(out, target, wrapper) do
    if staged_complete?(out) do
      File.rm_rf!(target)
      _ = File.rename(out, target)
      Logger.info("staged container harness at #{wrapper}")
      {:ok, wrapper}
    else
      {:error,
       {:harness_build_failed, "staging reported success but produced no runtime at #{out}"}}
    end
  end

  defp trim_output(output) do
    output |> String.trim() |> String.slice(0, 500)
  end
end
