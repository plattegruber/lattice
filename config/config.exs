# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :lattice,
  generators: [timestamp_type: :utc_datetime]

# Capability module implementations — swap per environment
config :lattice, :capabilities,
  sprites: Lattice.Capabilities.Sprites.Live,
  github: Lattice.Capabilities.GitHub.Stub,
  fly: Lattice.Capabilities.Fly.Live,
  secret_store: Lattice.Capabilities.SecretStore.Env

# Fleet configuration — sprites to discover and manage at boot
config :lattice, :fleet, sprites: []

# Fleet reconciliation intervals (adaptive: fast when viewers present, slow otherwise)
config :lattice, :fleet_reconcile_fast_ms, 10_000
config :lattice, :fleet_reconcile_slow_ms, 60_000

# Auth provider — stub for dev, Clerk for production
config :lattice, :auth, provider: Lattice.Auth.Stub

# Safety guardrails — action gating and approval requirements
config :lattice, :guardrails,
  allow_controlled: true,
  allow_dangerous: false,
  require_approval_for_controlled: true

# Task allowlist — repos that auto-approve task intents
config :lattice, :task_allowlist, auto_approve_repos: []

# Configure the endpoint
config :lattice, LatticeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LatticeWeb.ErrorHTML, json: LatticeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Lattice.PubSub,
  live_view: [signing_salt: "XumPY0lI"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  lattice: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  lattice: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :sprite_id,
    :from_state,
    :to_state,
    :reason,
    :outcome,
    :duration_ms,
    :details,
    :status,
    :check_duration_ms,
    :message,
    :action,
    :classification,
    :capability,
    :operation,
    :result,
    :total,
    :by_state,
    :actor,
    :args,
    :instance_name,
    :environment,
    :github_repo,
    :fly_org,
    :fly_app,
    :sprites_api_base,
    :sprite_ids,
    :observation_id,
    :type,
    :severity,
    :intent_id,
    :kind,
    :source,
    :from,
    :to,
    :artifact_type
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
