defmodule Lattice.Connections.WebhookSetup do
  @moduledoc """
  Automatically creates and deletes GitHub webhooks when repos are
  connected and disconnected.

  On connect:
  - Generates a random webhook secret
  - Creates a webhook via `POST /repos/{owner}/{repo}/hooks`
  - Stores the secret in runtime config for `WebhookSignature` plug

  On disconnect:
  - Deletes the webhook via API
  - Clears the webhook secret from config
  """

  require Logger

  @api_base "https://api.github.com"
  @webhook_events ["issues", "issue_comment", "pull_request"]

  @doc """
  Create a webhook on the given repo.

  Returns `{:ok, webhook_id}` on success or `{:error, reason}` on failure.
  The webhook secret is stored in runtime config.
  """
  @spec create(String.t(), String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def create(repo, github_token, app_host) do
    secret = generate_secret()
    webhook_url = "#{app_host}/api/webhooks/github"

    payload = %{
      name: "web",
      active: true,
      events: @webhook_events,
      config: %{
        url: webhook_url,
        content_type: "json",
        secret: secret,
        insecure_ssl: "0"
      }
    }

    headers = request_headers(github_token)
    url = ~c"#{@api_base}/repos/#{repo}/hooks"
    body = Jason.encode!(payload) |> String.to_charlist()

    case :httpc.request(:post, {url, headers, ~c"application/json", body}, [timeout: 15_000], []) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status in [201, 200] ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, %{"id" => webhook_id}} ->
            store_webhook_config(secret, webhook_id)
            Logger.info("Created GitHub webhook #{webhook_id} for #{repo}")
            {:ok, webhook_id}

          _ ->
            {:error, :invalid_response}
        end

      {:ok, {{_, 422, _}, _headers, resp_body}} ->
        # May already exist
        body_str = to_string(resp_body)

        if String.contains?(body_str, "already exists") do
          Logger.info("Webhook already exists for #{repo}, updating secret")
          store_webhook_config(secret, nil)
          {:ok, 0}
        else
          {:error, {:validation_error, body_str}}
        end

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        Logger.warning("Webhook creation failed (#{status}): #{to_string(resp_body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Delete the webhook for the given repo.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(repo, github_token) do
    webhook_id = get_webhook_id()

    if webhook_id && webhook_id > 0 do
      headers = request_headers(github_token)
      url = ~c"#{@api_base}/repos/#{repo}/hooks/#{webhook_id}"

      case :httpc.request(:delete, {url, headers}, [timeout: 15_000], []) do
        {:ok, {{_, status, _}, _headers, _body}} when status in [204, 200, 404] ->
          clear_webhook_config()
          Logger.info("Deleted GitHub webhook #{webhook_id} for #{repo}")
          :ok

        {:ok, {{_, status, _}, _headers, body}} ->
          Logger.warning("Webhook deletion failed (#{status}): #{to_string(body)}")
          # Clear config anyway to avoid stale state
          clear_webhook_config()
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    else
      clear_webhook_config()
      :ok
    end
  end

  # ── Private ────────────────────────────────────────────────────────

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp store_webhook_config(secret, webhook_id) do
    webhooks = Application.get_env(:lattice, :webhooks, [])

    webhooks =
      webhooks
      |> Keyword.put(:github_secret, secret)
      |> Keyword.put(:github_webhook_id, webhook_id)

    Application.put_env(:lattice, :webhooks, webhooks)
  end

  defp clear_webhook_config do
    webhooks = Application.get_env(:lattice, :webhooks, [])

    webhooks =
      webhooks
      |> Keyword.delete(:github_secret)
      |> Keyword.delete(:github_webhook_id)

    Application.put_env(:lattice, :webhooks, webhooks)
  end

  defp get_webhook_id do
    Application.get_env(:lattice, :webhooks, [])
    |> Keyword.get(:github_webhook_id)
  end

  defp request_headers(token) do
    [
      {~c"authorization", ~c"Bearer #{token}"},
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"x-github-api-version", ~c"2022-11-28"},
      {~c"user-agent", ~c"Lattice/1.0"}
    ]
  end
end
