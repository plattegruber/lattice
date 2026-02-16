defmodule Lattice.Capabilities.SecretStore do
  @moduledoc """
  Behaviour for accessing secrets.

  Secrets (API keys, tokens, etc.) are accessed through this capability so
  the storage backend can be swapped without changing consuming code. The
  initial implementation reads from system environment variables; future
  implementations may use Vault, 1Password, etc.

  All callbacks return tagged tuples (`{:ok, value}` / `{:error, reason}`).
  """

  @typedoc "A secret key name."
  @type secret_key :: String.t()

  @doc "Retrieve a secret by its key name."
  @callback get_secret(secret_key()) :: {:ok, String.t()} | {:error, term()}

  @doc "Retrieve a secret by its key name."
  def get_secret(key), do: impl().get_secret(key)

  defp impl, do: Application.get_env(:lattice, :capabilities)[:secret_store]
end
