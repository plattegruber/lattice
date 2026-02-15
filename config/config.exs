import Config

config :lattice,
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :lattice, LatticeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LatticeWeb.ErrorHTML, json: LatticeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Lattice.PubSub,
  live_view: [signing_salt: "lattice_lv_salt"]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.17",
  lattice: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
