defmodule Lattice.Capabilities.GitHub.AppAuth do
  @moduledoc """
  GitHub App authentication using JWT + installation access tokens.

  Generates RS256-signed JWTs from the app's private key, then exchanges
  them for short-lived installation access tokens via the GitHub API.

  Tokens are cached in `:persistent_term` and refreshed ~5 minutes before
  expiry (installation tokens are valid for 1 hour).

  ## Configuration

      config :lattice, Lattice.Capabilities.GitHub.AppAuth,
        app_id: "12345",
        installation_id: "67890",
        private_key: "-----BEGIN RSA PRIVATE KEY-----\\n..."

  All three values are required. When any is missing, `token/0` returns `nil`
  and the system falls back to PAT-based auth.
  """

  require Logger

  @cache_key :lattice_github_app_token
  @refresh_margin_seconds 300

  @doc """
  Returns a valid installation access token, or `nil` if app auth is not configured.

  Fetches from cache when the token is still fresh, otherwise generates a new
  JWT and exchanges it for an installation token.
  """
  @spec token() :: String.t() | nil
  def token do
    case config() do
      {:ok, _app_id, _installation_id, _private_key} ->
        case cached_token() do
          {:ok, token} -> token
          :expired -> refresh_token()
        end

      :not_configured ->
        nil
    end
  end

  @doc """
  Returns `true` if GitHub App auth is fully configured.
  """
  @spec configured?() :: boolean()
  def configured? do
    match?({:ok, _, _, _}, config())
  end

  # ── Private: Token Lifecycle ─────────────────────────────────────

  defp cached_token do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        :expired

      {token, expires_at} ->
        now = System.system_time(:second)

        if now < expires_at - @refresh_margin_seconds do
          {:ok, token}
        else
          :expired
        end
    end
  end

  defp refresh_token do
    {:ok, app_id, installation_id, private_key} = config()

    jwt = generate_jwt(app_id, private_key)

    case fetch_installation_token(jwt, installation_id) do
      {:ok, token, expires_at} ->
        :persistent_term.put(@cache_key, {token, expires_at})
        Logger.info("GitHub App: refreshed installation token (expires in ~55min)")
        token

      {:error, reason} ->
        Logger.error("GitHub App: failed to fetch installation token: #{inspect(reason)}")
        nil
    end
  end

  # ── Private: JWT Generation ──────────────────────────────────────

  defp generate_jwt(app_id, private_key_pem) do
    [entry | _] = :public_key.pem_decode(private_key_pem)
    key = :public_key.pem_entry_decode(entry)

    now = System.system_time(:second)

    header = %{"alg" => "RS256", "typ" => "JWT"}

    payload = %{
      "iss" => app_id,
      "iat" => now - 60,
      "exp" => now + 600
    }

    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    payload_b64 = Base.url_encode64(Jason.encode!(payload), padding: false)

    signing_input = "#{header_b64}.#{payload_b64}"

    signature = :public_key.sign(signing_input, :sha256, key)
    signature_b64 = Base.url_encode64(signature, padding: false)

    "#{signing_input}.#{signature_b64}"
  end

  # ── Private: Installation Token Exchange ─────────────────────────

  defp fetch_installation_token(jwt, installation_id) do
    url = ~c"https://api.github.com/app/installations/#{installation_id}/access_tokens"

    headers = [
      {~c"authorization", ~c"Bearer #{jwt}"},
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"user-agent", ~c"Lattice/1.0"}
    ]

    request = {url, headers, ~c"application/json", ~c"{}"}
    http_opts = [timeout: 15_000, connect_timeout: 10_000]

    case :httpc.request(:post, request, http_opts, []) do
      {:ok, {{_, 201, _}, _resp_headers, resp_body}} ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, %{"token" => token, "expires_at" => expires_at_str}} ->
            expires_at = parse_expires_at(expires_at_str)
            {:ok, token, expires_at}

          {:ok, other} ->
            {:error, {:unexpected_response, other}}

          {:error, _} ->
            {:error, {:invalid_json, to_string(resp_body)}}
        end

      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        {:error, {:http_error, status, to_string(resp_body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp parse_expires_at(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt)
      _ -> System.system_time(:second) + 3600
    end
  end

  # ── Private: Configuration ───────────────────────────────────────

  defp config do
    cfg = Application.get_env(:lattice, __MODULE__, [])
    app_id = Keyword.get(cfg, :app_id)
    installation_id = Keyword.get(cfg, :installation_id)
    private_key = Keyword.get(cfg, :private_key)

    if app_id && installation_id && private_key do
      {:ok, app_id, installation_id, private_key}
    else
      :not_configured
    end
  end
end
