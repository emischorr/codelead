import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :code_lead, CodeLead.Repo,
  username: "postgres",
  password: "postgres",
  # PGHOST covers containerized dev — an agent running `mix test` inside
  # the repo's .devcontainer reaches the compose `db` service through it.
  hostname: System.get_env("PGHOST", "localhost"),
  database: "code_lead_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :code_lead, CodeLeadWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "eoquc+H4NY2XdujxuJlxKvG7pb9jQqQygNV+PLvDt9pEiPm3Fw6SKEZ0DjeK44TF",
  server: false

# Run Oban inline-on-demand only; no queues or plugins in test
config :code_lead, Oban, testing: :manual

# LLM calls hit a Req.Test stub instead of the network
config :code_lead, :llm_api_req_options, plug: {Req.Test, CodeLead.LlmApiStub}

# Subscription rate-limit pings hit a Req.Test stub instead of the network
config :code_lead, :subscription_usage_req_options,
  plug: {Req.Test, CodeLead.SubscriptionUsageStub}

# Never auto-poll in test — the always-running singleton would otherwise
# fire an unprompted Repo query outside any test's Ecto Sandbox ownership.
# Tests that need it start their own named instance and call refresh_now/1.
config :code_lead, CodeLead.Agents.SubscriptionUsageCache, auto_refresh: false

# Same sandbox concern for the boot-time workspace reconciliation —
# tests exercise it by calling CodeLead.Workspace.Reconciler.run/0.
config :code_lead, reconcile_workspace_at_boot: false

# Same reason as the reconciler above: a boot-time Repo query races
# the Ecto sandbox. Adoption is exercised by calling it directly.
config :code_lead, adopt_previews_at_boot: false

# In test we don't send emails, but the email surfaces are exercised — tests
# that need them hidden flip :mail_enabled themselves.
config :code_lead, CodeLead.Mailer, adapter: Swoosh.Adapters.Test
config :code_lead, mail_enabled: true

# The wizard's forge-token check must not reach github.com from a test.
config :code_lead, git_access_check: {CodeLead.GitHelpers, :check_access}

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
