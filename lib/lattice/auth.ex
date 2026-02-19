defmodule Lattice.Auth do
  @moduledoc """
  Behaviour for authenticating operators.

  Follows the same pattern as capability modules: a behaviour defines the
  contract, configuration selects the active implementation, and proxy
  functions delegate to the configured module.

  ## Implementations

  - `Lattice.Auth.Clerk` -- verifies Clerk JWTs via JWKS and maps Clerk
    users to Operator structs

  ## Configuration

  In `config/config.exs`:

      config :lattice, :auth,
        provider: Lattice.Auth.Clerk

  ## Usage

      case Lattice.Auth.verify_token(token) do
        {:ok, %Operator{}} -> # authenticated
        {:error, reason} -> # denied
      end
  """

  alias Lattice.Auth.Operator

  @doc """
  Verify a session token and return the authenticated Operator.
  """
  @callback verify_token(String.t()) :: {:ok, Operator.t()} | {:error, term()}

  @doc """
  Verify a session token using the configured auth provider.
  """
  @spec verify_token(String.t()) :: {:ok, Operator.t()} | {:error, term()}
  def verify_token(token), do: impl().verify_token(token)

  @doc """
  Returns the configured auth provider module.
  """
  @spec provider() :: module()
  def provider, do: impl()

  # ── Private ──────────────────────────────────────────────────────────

  defp impl do
    Application.get_env(:lattice, :auth, [])
    |> Keyword.get(:provider, Lattice.Auth.Clerk)
  end
end
