# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :front_seat, :scopes,
  user: [
    default: true,
    module: FrontSeat.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: FrontSeat.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :front_seat,
  ecto_repos: [FrontSeat.Repo],
  generators: [timestamp_type: :utc_datetime],
  # How the first-run wizard checks a forge token against the remote;
  # stubbed in test so the suite stays off the network.
  git_access_check: {FrontSeat.Git, :check_access}

# Configure the endpoint
config :front_seat, FrontSeatWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FrontSeatWeb.ErrorHTML, json: FrontSeatWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FrontSeat.PubSub,
  live_view: [signing_salt: "7RIZkNdC"]

# Background jobs. The cron plugin gains entries as workers are added
# (nightly cost rollups live in the :rollups queue).
config :front_seat, Oban,
  engine: Oban.Engines.Basic,
  repo: FrontSeat.Repo,
  queues: [rollups: 1, dispatch: 5],
  plugins: [
    {Oban.Plugins.Cron, crontab: [{"0 2 * * *", FrontSeat.Costs.RollupWorker}]}
  ]

# Launch commands for ACP harnesses, resolved against the PATH of the
# process running FrontSeat (not the execution context's). Overridable
# per environment. The Docker image bundles `claude-agent-acp`; `codex`
# is bring-your-own — see docs/configuration.md.
config :front_seat, :harnesses, %{
  claude_code: ["claude-agent-acp"],
  codex: ["codex", "acp"]
}

# Docker CLI argv prefix for the container executor. Tests swap it for a
# fake, mirroring the :harnesses pattern above.
config :front_seat, :docker_cli, ["docker"]

# Best-effort pricing (cents per million tokens) for cost_cents on
# agent_runs. Token counts stay exact; unknown models cost 0.
config :front_seat, :model_prices, %{
  "claude-sonnet-5" => %{input_cents_per_mtok: 300, output_cents_per_mtok: 1500},
  "claude-opus-5" => %{input_cents_per_mtok: 1500, output_cents_per_mtok: 7500},
  "claude-haiku-4-5-20251001" => %{input_cents_per_mtok: 100, output_cents_per_mtok: 500}
}

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# In production a real adapter is configured from SMTP_* in
# `config/runtime.exs`; without those vars the instance has no transport.
config :front_seat, FrontSeat.Mailer, adapter: Swoosh.Adapters.Local

# Email is opt-in. Off means every email surface (magic-link login, invites)
# is hidden rather than silently failing — see `FrontSeat.Mailer`. dev and test
# turn it on; prod only does so when SMTP_HOST is set.
config :front_seat, mail_enabled: false
config :front_seat, mail_from: {"FrontSeat", "frontseat@localhost"}

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  front_seat: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    # deps_path/0 rather than "../deps": the devcontainer moves dependency
    # source off the shared workspace mount via MIX_DEPS_PATH.
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  front_seat: [
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
