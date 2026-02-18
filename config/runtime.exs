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
    Keyword.put(capabilities, :github, Lattice.Capabilities.GitHub.Live)
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

# Auth provider: use Clerk when secret key is configured, otherwise stub
if System.get_env("CLERK_SECRET_KEY") do
  config :lattice, :auth, provider: Lattice.Auth.Clerk
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
