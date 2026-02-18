defmodule LatticeWeb.Api.WebhookController do
  @moduledoc """
  Controller for receiving GitHub webhook events.

  Handles `POST /api/webhooks/github`. Webhook requests are authenticated
  via HMAC-SHA256 signature (not bearer token). Event deduplication uses
  the `X-GitHub-Delivery` header.

  ## Flow

  1. Signature verified by `LatticeWeb.Plugs.WebhookSignature` (in pipeline)
  2. Delivery ID checked against `Lattice.Webhooks.Dedup`
  3. Event type extracted from `X-GitHub-Event` header
  4. Dispatched to `Lattice.Webhooks.GitHub.handle_event/2`
  """

  use LatticeWeb, :controller

  alias Lattice.Webhooks.Dedup
  alias Lattice.Webhooks.GitHub, as: WebhookHandler

  require Logger

  @doc """
  POST /api/webhooks/github — receive and process a GitHub webhook event.
  """
  def github(conn, params) do
    with {:ok, event_type} <- get_event_type(conn),
         {:ok, delivery_id} <- get_delivery_id(conn),
         :ok <- check_dedup(delivery_id) do
      emit_received(event_type, delivery_id)

      case WebhookHandler.handle_event(event_type, params) do
        {:ok, intent} ->
          emit_intent_proposed(event_type, intent)

          conn
          |> put_status(200)
          |> json(%{status: "processed", intent_id: intent.id})

        :ignored ->
          conn
          |> put_status(200)
          |> json(%{status: "ignored"})

        {:error, reason} ->
          Logger.warning("Webhook handler error",
            event_type: event_type,
            delivery_id: delivery_id,
            reason: inspect(reason)
          )

          conn
          |> put_status(422)
          |> json(%{error: "Failed to process webhook", detail: inspect(reason)})
      end
    else
      {:error, :missing_event_type} ->
        conn
        |> put_status(400)
        |> json(%{error: "Missing X-GitHub-Event header"})

      {:error, :missing_delivery_id} ->
        conn
        |> put_status(400)
        |> json(%{error: "Missing X-GitHub-Delivery header"})

      {:error, :duplicate} ->
        conn
        |> put_status(200)
        |> json(%{status: "duplicate"})
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp get_event_type(conn) do
    case Plug.Conn.get_req_header(conn, "x-github-event") do
      [event_type] when is_binary(event_type) -> {:ok, event_type}
      _ -> {:error, :missing_event_type}
    end
  end

  defp get_delivery_id(conn) do
    case Plug.Conn.get_req_header(conn, "x-github-delivery") do
      [delivery_id] when is_binary(delivery_id) -> {:ok, delivery_id}
      _ -> {:error, :missing_delivery_id}
    end
  end

  defp check_dedup(delivery_id) do
    if Dedup.seen?(delivery_id) do
      {:error, :duplicate}
    else
      :ok
    end
  end

  defp emit_received(event_type, delivery_id) do
    :telemetry.execute(
      [:lattice, :webhook, :received],
      %{system_time: System.system_time()},
      %{event_type: event_type, delivery_id: delivery_id}
    )
  end

  defp emit_intent_proposed(event_type, intent) do
    :telemetry.execute(
      [:lattice, :webhook, :intent_proposed],
      %{system_time: System.system_time()},
      %{event_type: event_type, intent: intent}
    )
  end
end
