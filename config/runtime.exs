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

# The same port again as plain app config: core code (the repository
# changeset blocks it as a preview port) reads it without touching the
# endpoint.
config :code_lead, app_port: String.to_integer(System.get_env("PORT", "4000"))

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
  max_concurrent_runs: String.to_integer(System.get_env("MAX_CONCURRENT_RUNS", "2")),
  # Image the workspace remover uses to delete root-owned leftovers of
  # container runs (a short-lived `docker run … rm -rf`). Any image with
  # a POSIX rm works; override for air-gapped registries.
  maintenance_image: System.get_env("MAINTENANCE_IMAGE", "alpine:3.20")

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
  # Scoped to the one-shot harness build container these days: task
  # containers get their user from the repo's devcontainer config
  # (resource caps likewise via runArgs/hostRequirements, ADR-0009).
  container_user: System.get_env("CONTAINER_USER"),
  workspace_volume: System.get_env("WORKSPACE_VOLUME"),
  workspace_volume_mount: System.get_env("WORKSPACE_VOLUME_MOUNT", "/data"),
  host_data_root: System.get_env("HOST_DATA_ROOT"),
  harness_version: System.get_env("HARNESS_VERSION", "0.66.0"),
  harness_source: System.get_env("HARNESS_SOURCE"),
  # The devcontainer CLI head (@devcontainers/cli). Baked into the
  # published image; a dev machine installs it with
  # `npm i -g @devcontainers/cli`.
  devcontainer_cli: [System.get_env("DEVCONTAINER_CLI", "devcontainer")]

# Live preview of container tasks. A relay sidecar (PREVIEW_RELAY_IMAGE,
# a socat image) joins the task container's network and publishes the
# declared `preview_port` on PREVIEW_PUBLISH_IP with an ephemeral host
# port; the in-app proxy dials PREVIEW_UPSTREAM_HOST on that port.
# Unset (the convention), both auto-resolve at runtime: loopback when
# the BEAM runs on the docker host (dev), the docker bridge gateway —
# asked from the daemon — when the app itself runs in a container (the
# deployed stack). Set them only for setups the detection cannot cover;
# see CodeLead.PreviewGateway.Address.
config :code_lead,
  preview_publish_ip: System.get_env("PREVIEW_PUBLISH_IP"),
  preview_upstream_host: System.get_env("PREVIEW_UPSTREAM_HOST"),
  preview_relay_image: System.get_env("PREVIEW_RELAY_IMAGE", "alpine/socat"),
  preview_idle_ms: String.to_integer(System.get_env("PREVIEW_IDLE_MINUTES", "30")) * 60_000,
  preview_start_timeout_ms:
    String.to_integer(System.get_env("PREVIEW_START_TIMEOUT_SECONDS", "120")) * 1_000,
  terminal_idle_ms: String.to_integer(System.get_env("TERMINAL_IDLE_MINUTES", "15")) * 60_000,
  # The path gateway's reload-loop breaker: repeated navigations to the
  # same /preview/<id>/ URL serve a diagnostic instead of proxying (an
  # app emitting root-absolute URLs that escape the mount makes its own
  # client reload forever). Each page offers a one-click bypass;
  # PREVIEW_LOOP_BREAKER=off disarms it instance-wide.
  preview_loop_breaker: System.get_env("PREVIEW_LOOP_BREAKER") != "off"

# Preview gateway selection. Unset (the convention), previews are served
# by the path gateway at /preview/<id>/ with zero configuration. Setting
# PREVIEW_DOMAIN (e.g. preview.example.com, wildcard-DNS'd at the same
# instance) switches the whole instance to per-task subdomain previews —
# task-<id>.<PREVIEW_DOMAIN> — for apps that break under path-prefix
# hosting. Exactly one gateway is active at a time. The recommended
# domain shares its registrable domain with PHX_HOST (same-site cookies);
# see docs/configuration.md. The test env ignores a dev shell's
# PREVIEW_DOMAIN, like WORKSPACE_ROOT above — tests pick their gateway
# via app env directly.
preview_domain = System.get_env("PREVIEW_DOMAIN")

if preview_domain not in [nil, ""] and config_env() != :test do
  preview_scheme = System.get_env("SCHEME", "http")

  # The port in generated preview URLs: URL_PORT when set, else the
  # scheme default in prod (proxy-fronted) and the listen port in dev
  # (task-42.preview.localhost:4000 works out of the box).
  preview_url_port =
    case {System.get_env("URL_PORT"), config_env()} do
      {nil, :prod} -> if preview_scheme == "https", do: 443, else: 80
      {nil, _dev} -> String.to_integer(System.get_env("PORT", "4000"))
      {value, _env} -> String.to_integer(value)
    end

  config :code_lead,
    preview_gateway: CodeLead.PreviewGateway.SubdomainProxy,
    preview_domain: preview_domain,
    preview_url: [scheme: preview_scheme, port: preview_url_port]
end

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

  ## Mail
  #
  # Email is opt-in and off unless SMTP_HOST is set. Off means no transport and
  # no email surfaces at all: the magic-link login form and the invite flows are
  # hidden, so the instance runs on usernames and passwords alone. Setting
  # SMTP_HOST points the mailer at a real relay and turns those surfaces on.
  if smtp_host = System.get_env("SMTP_HOST") do
    smtp_username = System.get_env("SMTP_USERNAME")
    smtp_password = System.get_env("SMTP_PASSWORD")

    # `if_available` upgrades with STARTTLS when the relay offers it. Use
    # `always` to require it, `never` for a plaintext relay on a trusted network.
    smtp_tls =
      case System.get_env("SMTP_TLS") || "if_available" do
        "always" -> :always
        "never" -> :never
        "if_available" -> :if_available
        other -> raise "SMTP_TLS must be always, never, or if_available — got #{inspect(other)}"
      end

    config :code_lead, CodeLead.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_host,
      port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
      username: smtp_username,
      password: smtp_password,
      # Implicit TLS (usually port 465), as opposed to STARTTLS above.
      ssl: System.get_env("SMTP_SSL") in ~w(true 1),
      tls: smtp_tls,
      tls_options: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(smtp_host),
        depth: 3
      ],
      auth: if(smtp_username, do: :always, else: :never),
      retries: 1

    config :code_lead, mail_enabled: true

    config :code_lead,
           :mail_from,
           {System.get_env("MAIL_FROM_NAME") || "CodeLead",
            System.get_env("MAIL_FROM") || "codelead@#{host}"}
  end
end
