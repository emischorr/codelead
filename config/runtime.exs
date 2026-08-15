import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/code_lead start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :code_lead, CodeLeadWeb.Endpoint, server: true
end

# The port the endpoint binds to. It has no bearing on the port in generated
# links — that is URL_PORT, set in the prod block below.
config :code_lead, CodeLeadWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Encryption key for Cloak (provider credentials, project env store).
# Base64-encoded 32 bytes; generate with:
#
#     iex> 32 |> :crypto.strong_rand_bytes() |> Base.encode64()
#
# Dev/test fall back to a fixed key so the app boots without setup;
# prod requires ENCRYPTION_KEY.
encryption_key =
  case {System.get_env("ENCRYPTION_KEY"), config_env()} do
    {nil, :prod} ->
      raise """
      environment variable ENCRYPTION_KEY is missing.
      Generate one with: 32 |> :crypto.strong_rand_bytes() |> Base.encode64()
      """

    {nil, _dev_or_test} ->
      "3Jnb0hZiHIzHTOih7t2cTEPEpY98Tu1wvQkPfq/XwqE="

    {key, _env} ->
      key
  end

config :code_lead, CodeLead.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!(encryption_key), iv_length: 12}
  ]

# Signed license key for the instance. Optional everywhere, including
# prod: absent means the community tier, which today grants everything.
# See `CodeLead.License` and docs/licensing.md.
config :code_lead, CodeLead.License, key: System.get_env("LICENSE_KEY")

# Root directory for CodeLead-managed working state: base clones,
# per-task git worktrees, and task folders.
#
# The test env deliberately ignores WORKSPACE_ROOT: agent subprocesses
# inherit the server's environment, so `mix test` inside a task worktree
# would otherwise resolve — and wipe (test_helper.exs) — the instance's
# real workspace. TEST_WORKSPACE_ROOT is the explicit opt-out for CI and
# must point inside the checkout (enforced by test_helper.exs).
workspace_root =
  case config_env() do
    :test -> System.get_env("TEST_WORKSPACE_ROOT", Path.expand("tmp/test_workspace"))
    _dev_or_prod -> System.get_env("WORKSPACE_ROOT", Path.expand("workspace"))
  end

config :code_lead,
  workspace_root: workspace_root,
  max_concurrent_runs: String.to_integer(System.get_env("MAX_CONCURRENT_RUNS", "3"))

# Container executor (ADR-0003/0004/0005). How sibling task containers see
# the workspace: a named volume when WORKSPACE_VOLUME is set (the deployed
# stack), a HOST_DATA_ROOT bind as the escape hatch, else a bind of
# workspace_root at the identical path (dev, where the BEAM runs on the
# host). The staged harness (a runtime directory per libc flavor) is built
# lazily in-docker on the first container run needing the flavor; a
# HARNESS_SOURCE directory of pre-staged flavor dirs is the air-gapped
# escape hatch, copied at boot. HARNESS_VERSION's default must stay in
# sync with the Dockerfile's ARG CLAUDE_ACP_VERSION.
config :code_lead,
  container_user: System.get_env("CONTAINER_USER"),
  container_cpus: System.get_env("CONTAINER_CPUS"),
  container_memory_mb: System.get_env("CONTAINER_MEMORY_MB"),
  workspace_volume: System.get_env("WORKSPACE_VOLUME"),
  workspace_volume_mount: System.get_env("WORKSPACE_VOLUME_MOUNT", "/data"),
  host_data_root: System.get_env("HOST_DATA_ROOT"),
  harness_version: System.get_env("HARNESS_VERSION", "0.66.0"),
  harness_source: System.get_env("HARNESS_SOURCE")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :code_lead, CodeLead.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  scheme = System.get_env("SCHEME") || "http"

  # The port that appears in generated absolute URLs — independent of the
  # listen port (PORT, set above). It defaults to the scheme's standard port,
  # which is what a proxy-fronted instance wants; set it only when the app is
  # reached directly on a non-standard port.
  url_port =
    case System.get_env("URL_PORT") do
      nil -> if scheme == "https", do: 443, else: 80
      value -> String.to_integer(value)
    end

  # Origins allowed to open the LiveView WebSocket. PHX_HOST is always allowed;
  # ALLOWED_HOSTS adds more, so one instance can be reached at several addresses
  # at once — e.g. directly by IP over http and through a TLS-terminating proxy
  # on a domain. Entries are bare hosts ("10.0.0.5", "*.example.com"), which
  # match any scheme and port, or full origins ("http://10.0.0.5:4000"), which
  # must match exactly. "*" disables the check entirely.
  allowed_hosts =
    "ALLOWED_HOSTS"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  check_origin =
    if "*" in allowed_hosts do
      false
    else
      [host | allowed_hosts]
      |> Enum.map(fn entry ->
        if String.contains?(entry, "//"), do: entry, else: "//" <> entry
      end)
      |> Enum.uniq()
    end

  config :code_lead, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :code_lead, CodeLeadWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :code_lead, CodeLeadWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :code_lead, CodeLeadWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :code_lead, CodeLead.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
