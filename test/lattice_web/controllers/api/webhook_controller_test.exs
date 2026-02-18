defmodule LatticeWeb.Api.WebhookControllerTest do
  use LatticeWeb.ConnCase

  @moduletag :unit

  alias Lattice.Intents.Store.ETS, as: StoreETS
  alias Lattice.Webhooks.Dedup

  @secret "test-webhook-secret"

  setup do
    StoreETS.reset()
    Dedup.reset()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp sign(body) do
    :crypto.mac(:hmac, :sha256, @secret, body)
    |> Base.encode16(case: :lower)
  end

  defp webhook_conn(conn, event_type, payload, opts \\ []) do
    delivery_id =
      Keyword.get(opts, :delivery_id, "delivery-#{System.unique_integer([:positive])}")

    body = Jason.encode!(payload)
    signature = sign(body)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-github-event", event_type)
    |> put_req_header("x-github-delivery", delivery_id)
    |> put_req_header("x-hub-signature-256", "sha256=#{signature}")
    |> post("/api/webhooks/github", body)
  end

  # ── issues.opened with lattice-work label ──────────────────────────

  describe "POST /api/webhooks/github — issues.opened" do
    test "creates intent from issue with lattice-work label", %{conn: conn} do
      payload = %{
        "action" => "opened",
        "issue" => %{
          "number" => 42,
          "title" => "Fix login bug",
          "body" => "Login is broken",
          "labels" => [%{"name" => "lattice-work"}]
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "alice"}
      }

      conn = webhook_conn(conn, "issues", payload)

      assert %{"status" => "processed", "intent_id" => intent_id} = json_response(conn, 200)
      assert is_binary(intent_id)
    end

    test "ignores issue without lattice-work label", %{conn: conn} do
      payload = %{
        "action" => "opened",
        "issue" => %{
          "number" => 43,
          "title" => "Normal issue",
          "body" => "Nothing special",
          "labels" => [%{"name" => "bug"}]
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "bob"}
      }

      conn = webhook_conn(conn, "issues", payload)

      assert %{"status" => "ignored"} = json_response(conn, 200)
    end
  end

  # ── pull_request.review_submitted ──────────────────────────────────

  describe "POST /api/webhooks/github — pull_request review" do
    test "creates intent when changes_requested", %{conn: conn} do
      payload = %{
        "action" => "review_submitted",
        "pull_request" => %{
          "number" => 99,
          "title" => "Add feature"
        },
        "review" => %{
          "state" => "changes_requested",
          "body" => "Fix the tests",
          "user" => %{"login" => "reviewer"}
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "reviewer"}
      }

      conn = webhook_conn(conn, "pull_request", payload)

      assert %{"status" => "processed", "intent_id" => _} = json_response(conn, 200)
    end

    test "ignores approved review", %{conn: conn} do
      payload = %{
        "action" => "review_submitted",
        "pull_request" => %{
          "number" => 99,
          "title" => "Add feature"
        },
        "review" => %{
          "state" => "approved",
          "body" => "LGTM",
          "user" => %{"login" => "reviewer"}
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "reviewer"}
      }

      conn = webhook_conn(conn, "pull_request", payload)

      assert %{"status" => "ignored"} = json_response(conn, 200)
    end
  end

  # ── Deduplication ──────────────────────────────────────────────────

  describe "deduplication" do
    test "rejects duplicate delivery IDs", %{conn: conn} do
      payload = %{
        "action" => "opened",
        "issue" => %{
          "number" => 50,
          "title" => "Dedup test",
          "body" => "",
          "labels" => [%{"name" => "lattice-work"}]
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "test"}
      }

      delivery_id = "fixed-delivery-id"

      conn1 = webhook_conn(conn, "issues", payload, delivery_id: delivery_id)
      assert %{"status" => "processed"} = json_response(conn1, 200)

      conn2 = webhook_conn(build_conn(), "issues", payload, delivery_id: delivery_id)
      assert %{"status" => "duplicate"} = json_response(conn2, 200)
    end
  end

  # ── Missing headers ────────────────────────────────────────────────

  describe "missing headers" do
    test "returns 400 when X-GitHub-Event is missing", %{conn: conn} do
      body = Jason.encode!(%{"action" => "opened"})
      signature = sign(body)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-delivery", "delivery-123")
        |> put_req_header("x-hub-signature-256", "sha256=#{signature}")
        |> post("/api/webhooks/github", body)

      assert %{"error" => "Missing X-GitHub-Event header"} = json_response(conn, 400)
    end

    test "returns 400 when X-GitHub-Delivery is missing", %{conn: conn} do
      body = Jason.encode!(%{"action" => "opened"})
      signature = sign(body)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "issues")
        |> put_req_header("x-hub-signature-256", "sha256=#{signature}")
        |> post("/api/webhooks/github", body)

      assert %{"error" => "Missing X-GitHub-Delivery header"} = json_response(conn, 400)
    end
  end

  # ── Signature rejection ────────────────────────────────────────────

  describe "signature verification" do
    test "rejects request with invalid signature", %{conn: conn} do
      body = Jason.encode!(%{"action" => "opened"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-github-event", "issues")
        |> put_req_header("x-github-delivery", "delivery-bad")
        |> put_req_header("x-hub-signature-256", "sha256=badbadbadbad")
        |> post("/api/webhooks/github", body)

      assert conn.status == 401
    end
  end

  # ── Unhandled events ───────────────────────────────────────────────

  describe "unhandled events" do
    test "returns ignored for ping events", %{conn: conn} do
      payload = %{"zen" => "Keep it logically awesome"}

      conn = webhook_conn(conn, "ping", payload)

      assert %{"status" => "ignored"} = json_response(conn, 200)
    end
  end
end
