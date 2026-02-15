import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# application is started, so it is typically used to load production
# configuration and secrets from environment variables or elsewhere.

if System.get_env("PHX_SERVER") do
  config :lattice, LatticeWeb.Endpoint, server: true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :lattice, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :lattice, LatticeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
end

# Lattice instance configuration
config :lattice, :instance,
  name: System.get_env("LATTICE_INSTANCE_NAME", "lattice-dev"),
  environment: config_env()

config :lattice, :resources,
  github_repo: System.get_env("GITHUB_REPO"),
  fly_org: System.get_env("FLY_ORG"),
  fly_app: System.get_env("FLY_APP"),
  sprites_api_base: System.get_env("SPRITES_API_BASE")
