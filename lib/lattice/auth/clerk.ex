defmodule Lattice.Auth.Clerk do
  @moduledoc """
  Clerk auth provider that verifies session JWTs.

  Clerk issues RS256-signed JWTs for authenticated sessions. This module
  verifies those tokens using Clerk's JWKS (JSON Web Key Set) endpoint,
  then maps the Clerk user to a Lattice Operator struct.

  ## How It Works

  1. Decode the JWT header to confirm RS256 algorithm and extract the `kid`
  2. Fetch the JWKS from Clerk's Backend API (cached in ETS)
  3. Find the matching public key by `kid`
  4. Verify the RSA signature using Erlang's `:public_key` module
  5. Validate claims (`exp`, `nbf`)
  6. Fetch user details from Clerk's API to build the Operator struct

  ## Configuration

  Required environment variables (read at runtime):
  - `CLERK_SECRET_KEY` -- Clerk secret key for API calls

  ## Role Mapping

  Clerk user metadata can contain a `lattice_role` field in `public_metadata`.
  If not present, defaults to `:operator`.
  """

  @behaviour Lattice.Auth

  alias Lattice.Auth.Operator

  require Logger

  @jwks_ets_table :lattice_clerk_jwks
  @jwks_cache_ttl_ms :timer.minutes(60)

  # ── Public API ─────────────────────────────────────────────────────

  @impl true
  def verify_token(token) when is_binary(token) do
    with {:ok, header, payload} <- decode_jwt(token),
         :ok <- validate_algorithm(header),
         kid = Map.get(header, "kid"),
         {:ok, jwk} <- fetch_jwk(kid),
         {:ok, public_key} <- jwk_to_public_key(jwk),
         :ok <- verify_signature(token, public_key),
         :ok <- validate_claims(payload) do
      build_operator(payload)
    end
  end

  def verify_token(_token), do: {:error, :invalid_token}

  # ── JWT Decoding ───────────────────────────────────────────────────

  defp decode_jwt(token) do
    case String.split(token, ".") do
      [header_b64, payload_b64, _signature] ->
        with {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
             {:ok, header} <- Jason.decode(header_json),
             {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
             {:ok, payload} <- Jason.decode(payload_json) do
          {:ok, header, payload}
        else
          _ -> {:error, :malformed_token}
        end

      _ ->
        {:error, :malformed_token}
    end
  end

  defp validate_algorithm(%{"alg" => "RS256"}), do: :ok
  defp validate_algorithm(_), do: {:error, :unsupported_algorithm}

  # ── JWKS Fetching ──────────────────────────────────────────────────

  defp fetch_jwk(kid) do
    case get_cached_jwks() do
      {:ok, keys} ->
        find_key(keys, kid)

      :miss ->
        case fetch_and_cache_jwks() do
          {:ok, keys} -> find_key(keys, kid)
          {:error, _} = error -> error
        end
    end
  end

  defp find_key(keys, kid) do
    case Enum.find(keys, fn key -> Map.get(key, "kid") == kid end) do
      nil -> {:error, :key_not_found}
      key -> {:ok, key}
    end
  end

  defp get_cached_jwks do
    ensure_ets_table()

    case :ets.lookup(@jwks_ets_table, :jwks) do
      [{:jwks, keys, cached_at}] ->
        if System.monotonic_time(:millisecond) - cached_at < @jwks_cache_ttl_ms do
          {:ok, keys}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  defp fetch_and_cache_jwks do
    secret_key = clerk_secret_key()

    if is_nil(secret_key) or secret_key == "" do
      {:error, :clerk_secret_key_not_configured}
    else
      fetch_jwks_from_clerk(secret_key)
    end
  end

  defp fetch_jwks_from_clerk(secret_key) do
    jwks_url = "https://api.clerk.com/v1/jwks"

    headers = [
      {~c"authorization", ~c"Bearer #{secret_key}"},
      {~c"accept", ~c"application/json"}
    ]

    case :httpc.request(:get, {String.to_charlist(jwks_url), headers}, [], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        parse_and_cache_jwks(body)

      {:ok, {{_, status, _}, _headers, _body}} ->
        Logger.warning("Clerk JWKS fetch failed with status #{status}")
        {:error, {:jwks_fetch_failed, status}}

      {:error, reason} ->
        Logger.warning("Clerk JWKS fetch error: #{inspect(reason)}")
        {:error, {:jwks_fetch_error, reason}}
    end
  end

  defp parse_and_cache_jwks(body) do
    case Jason.decode(to_string(body)) do
      {:ok, %{"keys" => keys}} ->
        ensure_ets_table()
        :ets.insert(@jwks_ets_table, {:jwks, keys, System.monotonic_time(:millisecond)})
        {:ok, keys}

      _ ->
        {:error, :invalid_jwks_response}
    end
  end

  defp ensure_ets_table do
    case :ets.whereis(@jwks_ets_table) do
      :undefined ->
        :ets.new(@jwks_ets_table, [:set, :public, :named_table])

      _ ->
        :ok
    end
  end

  # ── RSA Signature Verification ─────────────────────────────────────

  defp jwk_to_public_key(%{"kty" => "RSA", "n" => n_b64, "e" => e_b64}) do
    with {:ok, n_bytes} <- Base.url_decode64(n_b64, padding: false),
         {:ok, e_bytes} <- Base.url_decode64(e_b64, padding: false) do
      n = :crypto.bytes_to_integer(n_bytes)
      e = :crypto.bytes_to_integer(e_bytes)
      {:ok, {:RSAPublicKey, n, e}}
    else
      _ -> {:error, :invalid_jwk}
    end
  end

  defp jwk_to_public_key(_), do: {:error, :unsupported_key_type}

  defp verify_signature(token, public_key) do
    [header_b64, payload_b64, signature_b64] = String.split(token, ".")
    signing_input = "#{header_b64}.#{payload_b64}"

    case Base.url_decode64(signature_b64, padding: false) do
      {:ok, signature} ->
        if :public_key.verify(signing_input, :sha256, signature, public_key) do
          :ok
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :malformed_signature}
    end
  end

  # ── Claim Validation ───────────────────────────────────────────────

  defp validate_claims(payload) do
    now = System.system_time(:second)

    with :ok <- validate_exp(payload, now) do
      validate_nbf(payload, now)
    end
  end

  defp validate_exp(%{"exp" => exp}, now) when is_integer(exp) do
    if now < exp, do: :ok, else: {:error, :token_expired}
  end

  defp validate_exp(_, _), do: {:error, :missing_exp_claim}

  defp validate_nbf(%{"nbf" => nbf}, now) when is_integer(nbf) do
    # Allow 30 seconds of clock skew
    if now >= nbf - 30, do: :ok, else: {:error, :token_not_yet_valid}
  end

  # nbf is optional
  defp validate_nbf(_, _), do: :ok

  # ── Operator Building ──────────────────────────────────────────────

  defp build_operator(payload) do
    user_id = Map.get(payload, "sub", "unknown")

    # Clerk JWT claims may include user metadata
    # The full name can come from session claims or we fall back to the user ID
    name = extract_name(payload)
    role = extract_role(payload)

    Operator.new(user_id, name, role)
  end

  defp extract_name(payload) do
    # Clerk session JWTs may include custom claims via JWT templates
    # Fall back to subject ID if no name is available
    case payload do
      %{"name" => name} when is_binary(name) and name != "" -> name
      %{"first_name" => first, "last_name" => last} -> "#{first} #{last}" |> String.trim()
      %{"sub" => sub} -> sub
      _ -> "Unknown Operator"
    end
  end

  defp extract_role(payload) do
    # Check for a custom lattice_role claim in public metadata
    case get_in(payload, ["public_metadata", "lattice_role"]) do
      "admin" -> :admin
      "viewer" -> :viewer
      "operator" -> :operator
      _ -> :operator
    end
  end

  # ── Config ─────────────────────────────────────────────────────────

  defp clerk_secret_key do
    System.get_env("CLERK_SECRET_KEY")
  end
end
