defmodule Lattice.Capabilities do
  @moduledoc """
  Capability modules are the boundary between Lattice's internal process model
  and the outside world.

  Each external system (Sprites API, GitHub, Fly.io, secret stores) gets a
  behaviour module that defines a bounded interface. This enables:

  - Compile-time guarantees via `@callback` definitions
  - Easy mocking in tests via Mox
  - Swappable implementations selected by configuration

  ## Pattern

  Each capability follows the same shape:

  1. A behaviour module defines `@callback` specs returning tagged tuples
  2. The behaviour module exposes proxy functions that delegate to the
     configured implementation
  3. Configuration selects the active implementation per environment
  4. Mox mocks or stub implementations provide test doubles

  ## Configuration

  In `config/config.exs` (or environment-specific configs):

      config :lattice, :capabilities,
        sprites: Lattice.Capabilities.Sprites.Live,
        github: Lattice.Capabilities.GitHub.Stub,
        fly: Lattice.Capabilities.Fly.Live,
        secret_store: Lattice.Capabilities.SecretStore.Env

  ## Adding a New Capability

  1. Define a behaviour module in `lib/lattice/capabilities/your_capability.ex`
  2. Add `@callback` definitions returning `{:ok, result} | {:error, reason}`
  3. Add proxy functions that delegate to `impl()`
  4. Create a stub implementation in `your_capability/stub.ex`
  5. Register the implementation in config
  6. Write tests for the stub
  """

  @doc """
  Returns the configured implementation module for the given capability.

  ## Examples

      Lattice.Capabilities.impl(:sprites)
      #=> Lattice.Capabilities.Sprites.Live

      Lattice.Capabilities.impl(:github)
      #=> Lattice.Capabilities.GitHub.Stub
  """
  @spec impl(atom()) :: module()
  def impl(capability) when is_atom(capability) do
    :lattice
    |> Application.get_env(:capabilities, %{})
    |> Access.get(capability) ||
      raise ArgumentError, "no implementation configured for capability #{inspect(capability)}"
  end
end
