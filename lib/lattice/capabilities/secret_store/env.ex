defmodule Lattice.Capabilities.SecretStore.Env do
  @moduledoc """
  Environment variable implementation of the SecretStore capability.

  Reads secrets from system environment variables. This is the default
  implementation for development and early production. Future implementations
  may use Vault, 1Password, or other secret management systems.
  """

  @behaviour Lattice.Capabilities.SecretStore

  @impl true
  def get_secret(key) when is_binary(key) do
    case System.get_env(key) do
      nil -> {:error, {:not_found, key}}
      value -> {:ok, value}
    end
  end
end
