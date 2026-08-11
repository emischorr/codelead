# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :code_lead, :scopes,
  user: [
    default: true,
    module: CodeLead.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: CodeLead.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :code_lead,
  ecto_repos: [CodeLead.Repo],
  generators: [timestamp_type: :utc_datetime],
  # How the first-run wizard checks a forge token against the remote;
  # stubbed in test so the suite stays off the network.
  git_access_check: {CodeLead.Git, :check_access}

# Configure the endpoint
config :code_lead, CodeLeadWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CodeLeadWeb.ErrorHTML, json: CodeLeadWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CodeLead.PubSub,
  live_view: [signing_salt: "7RIZkNdC"]

# Background jobs. The cron plugin gains entries as workers are added
# (nightly cost rollups live in the :rollups queue).
config :code_lead, Oban,
  engine: Oban.Engines.Basic,
  repo: CodeLead.Repo,
  queues: [rollups: 1],
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"0 2 * * *", CodeLead.Costs.RollupWorker}]}
  ]

# Launch commands for ACP harnesses, resolved against the PATH of the
# process running CodeLead (not the execution context's). Overridable
# per environment. The Docker image bundles `claude-agent-acp`; `codex`
# is bring-your-own — see docs/configuration.md.
config :code_lead, :harnesses, %{
  claude_code: ["claude-agent-acp"],
  codex: ["codex", "acp"]
}

# Best-effort pricing (cents per million tokens) for cost_cents on
# agent_runs. Token counts stay exact; unknown models cost 0.
config :code_lead, :model_prices, %{
  "claude-sonnet-5" => %{input_cents_per_mtok: 300, output_cents_per_mtok: 1500},
  "claude-opus-5" => %{input_cents_per_mtok: 1500, output_cents_per_mtok: 7500},
  "claude-haiku-4-5-20251001" => %{input_cents_per_mtok: 100, output_cents_per_mtok: 500}
}

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :code_lead, CodeLead.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  code_lead: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  code_lead: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
