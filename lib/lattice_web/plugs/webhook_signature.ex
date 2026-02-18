defmodule LatticeWeb.Plugs.WebhookSignature do
  @moduledoc """
  Plug that verifies GitHub webhook HMAC-SHA256 signatures.

  GitHub signs webhook payloads using a shared secret. This plug recomputes
  the HMAC-SHA256 hash of the raw request body and compares it to the
  signature in the `X-Hub-Signature-256` header.

  ## Usage

      plug LatticeWeb.Plugs.WebhookSignature

  Requires the raw body to be cached via `LatticeWeb.Plugs.CacheBodyReader`.
  The webhook secret is read from `Application.get_env(:lattice, :webhooks)[:github_secret]`.

  Returns 401 if:
  - No webhook secret is configured
  - The `X-Hub-Signature-256` header is missing
  - The signature does not match
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    secret = webhook_secret()

    if is_nil(secret) or secret == "" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{error: "Webhook secret not configured"}))
      |> halt()
    else
      verify_signature(conn, secret)
    end
  end

  defp verify_signature(conn, secret) do
    with {:ok, signature} <- get_signature(conn),
         {:ok, raw_body} <- get_raw_body(conn),
         :ok <- check_signature(raw_body, secret, signature) do
      conn
    else
      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: reason}))
        |> halt()
    end
  end

  defp get_signature(conn) do
    case get_req_header(conn, "x-hub-signature-256") do
      ["sha256=" <> signature] -> {:ok, signature}
      _ -> {:error, "Missing or invalid X-Hub-Signature-256 header"}
    end
  end

  defp get_raw_body(conn) do
    case conn.assigns[:raw_body] do
      nil -> {:error, "No raw body available for signature verification"}
      chunks -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp check_signature(raw_body, secret, expected_signature) do
    computed =
      :crypto.mac(:hmac, :sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(computed, expected_signature) do
      :ok
    else
      {:error, "Invalid webhook signature"}
    end
  end

  defp webhook_secret do
    :lattice
    |> Application.get_env(:webhooks, [])
    |> Keyword.get(:github_secret)
  end
end
