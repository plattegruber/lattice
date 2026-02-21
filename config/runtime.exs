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
#     PHX_SERVER=true bin/lattice start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :lattice, LatticeWeb.Endpoint, server: true
end

# Database configuration from DATABASE_URL
if database_url = System.get_env("DATABASE_URL") do
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :lattice, Lattice.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # Use Postgres-backed intent store in prod when DATABASE_URL is set
  config :lattice, :intent_store, Lattice.Intents.Store.Postgres
end

config :lattice, LatticeWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Lattice instance configuration
config :lattice, :instance,
  name: System.get_env("LATTICE_INSTANCE_NAME", "lattice-dev"),
  environment: config_env()

config :lattice, :resources,
  github_repo: System.get_env("GITHUB_REPO"),
  fly_org: System.get_env("FLY_ORG"),
  fly_app: System.get_env("FLY_APP"),
  sprites_api_base: System.get_env("SPRITES_API_BASE")

# Capability auto-selection: use live implementations when credentials are present
capabilities = Application.get_env(:lattice, :capabilities, [])

capabilities =
  if System.get_env("GITHUB_REPO") do
    Keyword.put(capabilities, :github, Lattice.Capabilities.GitHub.Http)
  else
    capabilities
  end

capabilities =
  if System.get_env("FLY_APP") do
    Keyword.put(capabilities, :fly, Lattice.Capabilities.Fly.Live)
  else
    capabilities
  end

config :lattice, :capabilities, capabilities

# GitHub App authentication (preferred over PAT)
if System.get_env("GITHUB_APP_ID") do
  config :lattice, Lattice.Capabilities.GitHub.AppAuth,
    app_id: System.get_env("GITHUB_APP_ID"),
    installation_id: System.get_env("GITHUB_APP_INSTALLATION_ID"),
    private_key: System.get_env("GITHUB_APP_PRIVATE_KEY")
end

# Webhook secret for GitHub HMAC-SHA256 signature verification
if github_webhook_secret = System.get_env("GITHUB_WEBHOOK_SECRET") do
  config :lattice, :webhooks,
    github_secret: github_webhook_secret,
    dedup_ttl_ms: :timer.minutes(5)
end

# Ambient responder: enable when ANTHROPIC_API_KEY is set
if System.get_env("ANTHROPIC_API_KEY") do
  config :lattice, Lattice.Ambient.Responder,
    enabled: true,
    bot_login: System.get_env("LATTICE_BOT_LOGIN"),
    cooldown_ms: String.to_integer(System.get_env("AMBIENT_COOLDOWN_MS", "60000")),
    eyes_reaction: true

  config :lattice, Lattice.Ambient.Claude,
    api_key: System.get_env("ANTHROPIC_API_KEY"),
    model: System.get_env("AMBIENT_MODEL", "claude-sonnet-4-20250514")

  config :lattice, Lattice.Ambient.SpriteDelegate,
    enabled: System.get_env("AMBIENT_DELEGATION", "false") == "true",
    sprite_name: System.get_env("AMBIENT_SPRITE_NAME", "lattice-ambient"),
    work_dir: System.get_env("AMBIENT_WORK_DIR", "/home/sprite/lattice"),
    exec_idle_timeout_ms:
      String.to_integer(System.get_env("AMBIENT_EXEC_IDLE_TIMEOUT_MS", "1800000"))
end

# Auth provider: Clerk is the default; the secret key is required for prod
# (test env uses Lattice.MockAuth via config/test.exs)
if clerk_key = System.get_env("CLERK_SECRET_KEY") do
  config :lattice, :auth, provider: Lattice.Auth.Clerk, clerk_secret_key: clerk_key
end

if config_env() == :prod do
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

  config :lattice, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :lattice, LatticeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["//#{host}"],
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
  #     config :lattice, LatticeWeb.Endpoint,
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
  #     config :lattice, LatticeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
