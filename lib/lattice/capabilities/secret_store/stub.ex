defmodule Lattice.Capabilities.SecretStore.Stub do
  @moduledoc """
  Stub implementation of the SecretStore capability.

  Returns canned secrets for development and testing. Useful when you need
  predictable secret values without depending on actual environment variables.
  """

  @behaviour Lattice.Capabilities.SecretStore

  @stub_secrets %{
    "GITHUB_TOKEN" => "ghp_stub_token_for_testing",
    "FLY_API_TOKEN" => "fly_stub_token_for_testing",
    "SPRITES_API_KEY" => "sprites_stub_key_for_testing"
  }

  @impl true
  def get_secret(key) when is_binary(key) do
    case Map.get(@stub_secrets, key) do
      nil -> {:error, {:not_found, key}}
      value -> {:ok, value}
    end
  end
end
