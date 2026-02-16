# Define Mox mocks for capability behaviours.
# These are configured in config/test.exs as the default implementations.
Mox.defmock(Lattice.Capabilities.MockSprites, for: Lattice.Capabilities.Sprites)
Mox.defmock(Lattice.Capabilities.MockGitHub, for: Lattice.Capabilities.GitHub)
Mox.defmock(Lattice.Capabilities.MockFly, for: Lattice.Capabilities.Fly)
Mox.defmock(Lattice.Capabilities.MockSecretStore, for: Lattice.Capabilities.SecretStore)

ExUnit.start(exclude: [:integration])
