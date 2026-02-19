defmodule Lattice.Auth.ClerkGitHub do
  @moduledoc """
  Fetches GitHub OAuth access tokens from the Clerk Backend API.

  When an operator signs in via Clerk using GitHub OAuth, Clerk stores the
  operator's GitHub access token. This module retrieves that token so Lattice
  can make GitHub API calls on behalf of the operator.

  ## Usage

      case Lattice.Auth.ClerkGitHub.fetch_token(clerk_user_id) do
        {:ok, token} -> # use token for GitHub API calls
        {:error, reason} -> # handle error
      end

  ## Caching

  Tokens are cached in ETS with a configurable TTL (default 5 minutes) to
  avoid hitting the Clerk API on every GitHub operation.
  """

  require Logger

  @ets_table :lattice_clerk_github_tokens
  @cache_ttl_ms :timer.minutes(5)

  @doc """
  Fetch the GitHub OAuth access token for a Clerk user.

  Returns `{:ok, token}` on success or `{:error, reason}` on failure.
  Results are cached in ETS for #{div(@cache_ttl_ms, 60_000)} minutes.
  """
  @spec fetch_token(String.t()) :: {:ok, String.t()} | {:error, term()}
  def fetch_token(clerk_user_id) when is_binary(clerk_user_id) do
    case get_cached(clerk_user_id) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        case fetch_from_clerk(clerk_user_id) do
          {:ok, token} ->
            cache_token(clerk_user_id, token)
            {:ok, token}

          error ->
            error
        end
    end
  end

  @doc """
  Invalidate the cached token for a Clerk user.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(clerk_user_id) do
    ensure_ets_table()
    :ets.delete(@ets_table, clerk_user_id)
    :ok
  end

  # ── Private ────────────────────────────────────────────────────────

  defp get_cached(user_id) do
    ensure_ets_table()

    case :ets.lookup(@ets_table, user_id) do
      [{^user_id, token, cached_at}] ->
        if System.monotonic_time(:millisecond) - cached_at < @cache_ttl_ms do
          {:ok, token}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_token(user_id, token) do
    ensure_ets_table()
    :ets.insert(@ets_table, {user_id, token, System.monotonic_time(:millisecond)})
  end

  defp fetch_from_clerk(user_id) do
    secret_key = clerk_secret_key()

    if is_nil(secret_key) or secret_key == "" do
      {:error, :clerk_secret_key_not_configured}
    else
      url =
        ~c"https://api.clerk.com/v1/users/#{user_id}/oauth_access_tokens/github"

      headers = [
        {~c"authorization", ~c"Bearer #{secret_key}"},
        {~c"accept", ~c"application/json"}
      ]

      case :httpc.request(:get, {url, headers}, [timeout: 10_000], []) do
        {:ok, {{_, 200, _}, _headers, body}} ->
          parse_token_response(body)

        {:ok, {{_, status, _}, _headers, body}} ->
          Logger.warning("Clerk GitHub token fetch failed (status #{status}): #{to_string(body)}")

          {:error, {:clerk_api_error, status}}

        {:error, reason} ->
          Logger.warning("Clerk GitHub token fetch error: #{inspect(reason)}")
          {:error, {:clerk_request_failed, reason}}
      end
    end
  end

  defp parse_token_response(body) do
    case Jason.decode(to_string(body)) do
      {:ok, [%{"token" => token} | _]} when is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, []} ->
        {:error, :no_github_token_for_user}

      {:ok, _other} ->
        {:error, :unexpected_clerk_response}

      {:error, _} ->
        {:error, :invalid_clerk_response}
    end
  end

  defp ensure_ets_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:set, :public, :named_table])

      _ ->
        :ok
    end
  end

  defp clerk_secret_key do
    Application.get_env(:lattice, :auth, [])
    |> Keyword.get(:clerk_secret_key)
    |> case do
      nil -> System.get_env("CLERK_SECRET_KEY")
      key -> key
    end
  end
end
