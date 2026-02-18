import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :lattice, LatticeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CZGr/jaCPHgutB1Q9UGoirZB8Zqx0dLQB5IlH8+cF1i+IJiw6UDItsVIzFPL9ANn",
  server: false

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

# Use Mox mocks for capability modules in tests.
# Mox modules are defined in test/test_helper.exs.
# Individual tests can also use stubs directly by configuring per-test.
config :lattice, :capabilities,
  sprites: Lattice.Capabilities.MockSprites,
  github: Lattice.Capabilities.MockGitHub,
  fly: Lattice.Capabilities.MockFly,
  secret_store: Lattice.Capabilities.MockSecretStore

# Use stub auth provider in tests (returns a hardcoded dev operator)
config :lattice, :auth, provider: Lattice.Auth.Stub

# Empty fleet in tests — individual tests configure their own sprites
config :lattice, :fleet, sprites: []

# Test webhook secret for HMAC signature verification
config :lattice, :webhooks,
  github_secret: "test-webhook-secret",
  dedup_ttl_ms: :timer.minutes(5)
