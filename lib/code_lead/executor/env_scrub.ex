defmodule CodeLead.Executor.EnvScrub do
  @moduledoc """
  Removes CodeLead-internal environment variables from the environment
  handed to spawned agent processes.

  `LocalSubprocess` ports and ACP terminal commands inherit the BEAM's
  full environment, which on a deployed instance carries pointers to the
  instance's own state — `WORKSPACE_ROOT`, `DATABASE_URL`, secrets. An
  agent following those pointers can corrupt or destroy the instance
  (an agent's `mix test` inside a task worktree once resolved the
  inherited `WORKSPACE_ROOT` and wiped the workspace volume), so they
  are scrubbed rather than passed along.

  This is a denylist of CodeLead's own configuration names, never a
  whitelist — agents legitimately need `PATH`, `HOME`, `LANG`, proxy
  variables and whatever else the operator exported for them. A key the
  explicit env sets itself is left alone: a project env store entry
  named e.g. `DATABASE_URL` (for the target app) must win.
  """

  @internal ~w(
    WORKSPACE_ROOT DATABASE_URL SECRET_KEY_BASE ENCRYPTION_KEY LICENSE_KEY
    PHX_SERVER PHX_HOST ALLOWED_HOSTS SCHEME URL_PORT POOL_SIZE ECTO_IPV6
    DNS_CLUSTER_QUERY MAX_CONCURRENT_RUNS WORKSPACE_VOLUME WORKSPACE_VOLUME_MOUNT
    HOST_DATA_ROOT CONTAINER_USER CONTAINER_CPUS CONTAINER_MEMORY_MB
    HARNESS_VERSION HARNESS_SOURCE
  )

  @doc """
  Environment for `Port.open/2`'s `:env` option: the explicit pairs as
  charlists, preceded by removal entries (`{key, false}`) for internal
  variables the explicit env does not set itself.
  """
  @spec port_env([{String.t(), String.t()}]) :: [{charlist(), charlist() | false}]
  def port_env(explicit) do
    removals = for key <- to_scrub(explicit), do: {String.to_charlist(key), false}

    removals ++
      Enum.map(explicit, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)
  end

  @doc """
  Environment for `System.cmd/3`'s `:env` option: the explicit pairs,
  preceded by unset entries (`{key, nil}`) for internal variables the
  explicit env does not set itself.
  """
  @spec cmd_env([{String.t(), String.t()}]) :: [{String.t(), String.t() | nil}]
  def cmd_env(explicit) do
    for(key <- to_scrub(explicit), do: {key, nil}) ++ explicit
  end

  defp to_scrub(explicit) do
    explicit_keys = Enum.map(explicit, fn {key, _value} -> key end)
    @internal -- explicit_keys
  end
end
