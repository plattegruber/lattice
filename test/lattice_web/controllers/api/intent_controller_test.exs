defmodule LatticeWeb.Api.IntentControllerTest do
  use LatticeWeb.ConnCase

  alias Lattice.Intents.Store.ETS, as: StoreETS

  @moduletag :unit

  setup do
    StoreETS.reset()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp authenticated(conn) do
    put_req_header(conn, "authorization", "Bearer test-token")
  end

  defp valid_action_params do
    %{
      "kind" => "action",
      "source" => %{"type" => "sprite", "id" => "sprite-001"},
      "summary" => "List all sprites",
      "payload" => %{"capability" => "sprites", "operation" => "list_sprites"},
      "affected_resources" => ["sprites"],
      "expected_side_effects" => ["none"]
    }
  end

  defp valid_inquiry_params do
    %{
      "kind" => "inquiry",
      "source" => %{"type" => "operator", "id" => "op-001"},
      "summary" => "Need API key",
      "payload" => %{
        "what_requested" => "API key",
        "why_needed" => "Integration",
        "scope_of_impact" => "single service",
        "expiration" => "2026-03-01"
      }
    }
  end

  defp valid_maintenance_params do
    %{
      "kind" => "maintenance",
      "source" => %{"type" => "sprite", "id" => "sprite-001"},
      "summary" => "Update base image",
      "payload" => %{"image" => "elixir:1.18"}
    }
  end

  defp propose_awaiting_intent(conn) do
    previous = Application.get_env(:lattice, :guardrails, [])

    Application.put_env(:lattice, :guardrails,
      allow_controlled: true,
      require_approval_for_controlled: true
    )

    params = %{
      "kind" => "action",
      "source" => %{"type" => "sprite", "id" => "sprite-001"},
      "summary" => "Wake a sprite",
      "payload" => %{"capability" => "sprites", "operation" => "wake"},
      "affected_resources" => ["sprite-001"],
      "expected_side_effects" => ["sprite wakes"]
    }

    resp =
      conn
      |> authenticated()
      |> post("/api/intents", params)

    body = json_response(resp, 200)

    on_exit(fn ->
      Application.put_env(:lattice, :guardrails, previous)
    end)

    body["data"]
  end

  defp with_guardrails(config, fun) do
    previous = Application.get_env(:lattice, :guardrails, [])
    Application.put_env(:lattice, :guardrails, config)

    try do
      fun.()
    after
      Application.put_env(:lattice, :guardrails, previous)
    end
  end

  # ── GET /api/intents ─────────────────────────────────────────────

  describe "GET /api/intents" do
    test "returns empty list when no intents", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/intents")

      body = json_response(conn, 200)

      assert body["data"] == []
      assert is_binary(body["timestamp"])
    end

    test "lists all intents", %{conn: conn} do
      # Propose two intents
      conn
      |> authenticated()
      |> post("/api/intents", valid_action_params())

      conn
      |> authenticated()
      |> post("/api/intents", valid_maintenance_params())

      conn =
        conn
        |> authenticated()
        |> get("/api/intents")

      body = json_response(conn, 200)

      assert length(body["data"]) == 2
    end

    test "filters by kind", %{conn: conn} do
      conn
      |> authenticated()
      |> post("/api/intents", valid_action_params())

      conn
      |> authenticated()
      |> post("/api/intents", valid_maintenance_params())

      conn =
        conn
        |> authenticated()
        |> get("/api/intents", %{"kind" => "action"})

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert hd(body["data"])["kind"] == "action"
    end

    test "filters by state", %{conn: conn} do
      # Safe action auto-advances to approved
      conn
      |> authenticated()
      |> post("/api/intents", valid_action_params())

      conn =
        conn
        |> authenticated()
        |> get("/api/intents", %{"state" => "approved"})

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert hd(body["data"])["state"] == "approved"
    end

    test "filters by source_type", %{conn: conn} do
      conn
      |> authenticated()
      |> post("/api/intents", valid_action_params())

      conn =
        conn
        |> authenticated()
        |> get("/api/intents", %{"source_type" => "sprite"})

      body = json_response(conn, 200)

      assert length(body["data"]) == 1
      assert hd(body["data"])["source"]["type"] == "sprite"
    end

    test "ignores invalid filter values", %{conn: conn} do
      conn
      |> authenticated()
      |> post("/api/intents", valid_action_params())

      conn =
        conn
        |> authenticated()
        |> get("/api/intents", %{"kind" => "invalid"})

      body = json_response(conn, 200)

      # Invalid filter is ignored, returns all intents
      assert length(body["data"]) == 1
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/intents")

      assert json_response(conn, 401)
    end
  end

  # ── GET /api/intents/:id ─────────────────────────────────────────

  describe "GET /api/intents/:id" do
    test "returns intent detail with history", %{conn: conn} do
      resp =
        conn
        |> authenticated()
        |> post("/api/intents", valid_action_params())

      created = json_response(resp, 200)["data"]

      conn =
        conn
        |> authenticated()
        |> get("/api/intents/#{created["id"]}")

      body = json_response(conn, 200)

      assert body["data"]["id"] == created["id"]
      assert body["data"]["kind"] == "action"
      assert body["data"]["state"] == "approved"
      assert body["data"]["summary"] == "List all sprites"
      assert is_map(body["data"]["payload"])
      assert [_ | _] = body["data"]["transition_log"]
      assert is_binary(body["data"]["inserted_at"])
      assert is_binary(body["data"]["updated_at"])
      assert is_binary(body["timestamp"])
    end

    test "returns 404 for unknown intent", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/intents/nonexistent")

      body = json_response(conn, 404)

      assert body["error"] == "Intent not found"
      assert body["code"] == "INTENT_NOT_FOUND"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/intents/some-id")

      assert json_response(conn, 401)
    end
  end

  # ── POST /api/intents ────────────────────────────────────────────

  describe "POST /api/intents" do
    test "proposes an action intent (safe auto-approves)", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/intents", valid_action_params())

      body = json_response(conn, 200)

      assert body["data"]["kind"] == "action"
      assert body["data"]["state"] == "approved"
      assert body["data"]["classification"] == "safe"
      assert is_binary(body["data"]["id"])
      assert is_binary(body["timestamp"])
    end

    test "proposes a maintenance intent", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/intents", valid_maintenance_params())

      body = json_response(conn, 200)

      assert body["data"]["kind"] == "maintenance"
      assert body["data"]["state"] == "approved"
      assert body["data"]["classification"] == "safe"
    end

    test "proposes an inquiry intent (controlled, awaits approval)", %{conn: conn} do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          conn =
            conn
            |> authenticated()
            |> post("/api/intents", valid_inquiry_params())

          body = json_response(conn, 200)

          assert body["data"]["kind"] == "inquiry"
          assert body["data"]["state"] == "awaiting_approval"
          assert body["data"]["classification"] == "controlled"
        end
      )
    end

    test "returns 422 for invalid kind", %{conn: conn} do
      params = %{valid_action_params() | "kind" => "invalid"}

      conn =
        conn
        |> authenticated()
        |> post("/api/intents", params)

      body = json_response(conn, 422)

      assert body["code"] == "INVALID_KIND"
    end

    test "returns 422 when kind is missing", %{conn: conn} do
      params = Map.delete(valid_action_params(), "kind")

      conn =
        conn
        |> authenticated()
        |> post("/api/intents", params)

      body = json_response(conn, 422)

      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 when source is missing", %{conn: conn} do
      params = Map.delete(valid_action_params(), "source")

      conn =
        conn
        |> authenticated()
        |> post("/api/intents", params)

      body = json_response(conn, 422)

      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 for action intent missing affected_resources", %{conn: conn} do
      params = Map.delete(valid_action_params(), "affected_resources")

      conn =
        conn
        |> authenticated()
        |> post("/api/intents", params)

      body = json_response(conn, 422)

      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 for action intent missing expected_side_effects", %{conn: conn} do
      params = Map.delete(valid_action_params(), "expected_side_effects")

      conn =
        conn
        |> authenticated()
        |> post("/api/intents", params)

      body = json_response(conn, 422)

      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 422 for inquiry missing required payload fields", %{conn: conn} do
      params = %{
        valid_inquiry_params()
        | "payload" => %{"what_requested" => "API key"}
      }

      conn =
        conn
        |> authenticated()
        |> post("/api/intents", params)

      body = json_response(conn, 422)

      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = post(conn, "/api/intents", valid_action_params())

      assert json_response(conn, 401)
    end
  end

  # ── POST /api/intents/:id/approve ────────────────────────────────

  describe "POST /api/intents/:id/approve" do
    test "approves an awaiting intent", %{conn: conn} do
      intent_data = propose_awaiting_intent(conn)
      assert intent_data["state"] == "awaiting_approval"

      conn =
        conn
        |> authenticated()
        |> post("/api/intents/#{intent_data["id"]}/approve", %{"actor" => "human-reviewer"})

      body = json_response(conn, 200)

      assert body["data"]["id"] == intent_data["id"]
      assert body["data"]["state"] == "approved"
    end

    test "returns 404 for unknown intent", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/intents/nonexistent/approve", %{"actor" => "human"})

      body = json_response(conn, 404)

      assert body["code"] == "INTENT_NOT_FOUND"
    end

    test "returns 422 for invalid transition", %{conn: conn} do
      # Create a safe intent that auto-approves
      resp =
        conn
        |> authenticated()
        |> post("/api/intents", valid_action_params())

      created = json_response(resp, 200)["data"]
      assert created["state"] == "approved"

      # Trying to approve an already-approved intent
      conn =
        conn
        |> authenticated()
        |> post("/api/intents/#{created["id"]}/approve", %{"actor" => "human"})

      body = json_response(conn, 422)

      assert body["code"] == "INVALID_TRANSITION"
    end

    test "returns 422 when actor is missing", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/intents/some-id/approve", %{})

      body = json_response(conn, 422)

      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = post(conn, "/api/intents/some-id/approve", %{"actor" => "human"})

      assert json_response(conn, 401)
    end
  end

  # ── POST /api/intents/:id/reject ─────────────────────────────────

  describe "POST /api/intents/:id/reject" do
    test "rejects an awaiting intent", %{conn: conn} do
      intent_data = propose_awaiting_intent(conn)
      assert intent_data["state"] == "awaiting_approval"

      conn =
        conn
        |> authenticated()
        |> post("/api/intents/#{intent_data["id"]}/reject", %{
          "actor" => "reviewer",
          "reason" => "too risky"
        })

      body = json_response(conn, 200)

      assert body["data"]["id"] == intent_data["id"]
      assert body["data"]["state"] == "rejected"
    end

    test "returns 404 for unknown intent", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/intents/nonexistent/reject", %{"actor" => "human"})

      body = json_response(conn, 404)

      assert body["code"] == "INTENT_NOT_FOUND"
    end

    test "returns 422 for invalid transition", %{conn: conn} do
      resp =
        conn
        |> authenticated()
        |> post("/api/intents", valid_action_params())

      created = json_response(resp, 200)["data"]

      conn =
        conn
        |> authenticated()
        |> post("/api/intents/#{created["id"]}/reject", %{"actor" => "human"})

      body = json_response(conn, 422)

      assert body["code"] == "INVALID_TRANSITION"
    end

    test "returns 422 when actor is missing", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/intents/some-id/reject", %{})

      body = json_response(conn, 422)

      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = post(conn, "/api/intents/some-id/reject", %{"actor" => "human"})

      assert json_response(conn, 401)
    end
  end

  # ── POST /api/intents/:id/cancel ─────────────────────────────────

  describe "POST /api/intents/:id/cancel" do
    test "cancels an awaiting intent", %{conn: conn} do
      intent_data = propose_awaiting_intent(conn)
      assert intent_data["state"] == "awaiting_approval"

      conn =
        conn
        |> authenticated()
        |> post("/api/intents/#{intent_data["id"]}/cancel", %{
          "actor" => "operator",
          "reason" => "no longer needed"
        })

      body = json_response(conn, 200)

      assert body["data"]["id"] == intent_data["id"]
      assert body["data"]["state"] == "canceled"
    end

    test "cancels an approved intent", %{conn: conn} do
      resp =
        conn
        |> authenticated()
        |> post("/api/intents", valid_action_params())

      created = json_response(resp, 200)["data"]
      assert created["state"] == "approved"

      conn =
        conn
        |> authenticated()
        |> post("/api/intents/#{created["id"]}/cancel", %{"actor" => "operator"})

      body = json_response(conn, 200)

      assert body["data"]["state"] == "canceled"
    end

    test "returns 404 for unknown intent", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/intents/nonexistent/cancel", %{"actor" => "operator"})

      body = json_response(conn, 404)

      assert body["code"] == "INTENT_NOT_FOUND"
    end

    test "returns 422 for invalid transition (terminal state)", %{conn: conn} do
      intent_data = propose_awaiting_intent(conn)

      # First reject it
      conn
      |> authenticated()
      |> post("/api/intents/#{intent_data["id"]}/reject", %{"actor" => "reviewer"})

      # Then try to cancel the rejected intent
      conn =
        conn
        |> authenticated()
        |> post("/api/intents/#{intent_data["id"]}/cancel", %{"actor" => "operator"})

      body = json_response(conn, 422)

      assert body["code"] == "INVALID_TRANSITION"
    end

    test "returns 422 when actor is missing", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post("/api/intents/some-id/cancel", %{})

      body = json_response(conn, 422)

      assert body["code"] == "MISSING_FIELD"
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = post(conn, "/api/intents/some-id/cancel", %{"actor" => "operator"})

      assert json_response(conn, 401)
    end
  end

  # ── Full Lifecycle ───────────────────────────────────────────────

  describe "full lifecycle via API" do
    test "propose -> list -> approve -> verify state change", %{conn: conn} do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          # Step 1: Propose a controlled intent
          params = %{
            "kind" => "action",
            "source" => %{"type" => "sprite", "id" => "sprite-001"},
            "summary" => "Wake a sprite",
            "payload" => %{"capability" => "sprites", "operation" => "wake"},
            "affected_resources" => ["sprite-001"],
            "expected_side_effects" => ["sprite wakes"]
          }

          resp =
            conn
            |> authenticated()
            |> post("/api/intents", params)

          proposed = json_response(resp, 200)["data"]
          assert proposed["state"] == "awaiting_approval"

          # Step 2: List and verify the intent appears
          resp =
            conn
            |> authenticated()
            |> get("/api/intents")

          intents = json_response(resp, 200)["data"]
          assert length(intents) == 1
          assert hd(intents)["id"] == proposed["id"]

          # Step 3: Approve the intent
          resp =
            conn
            |> authenticated()
            |> post("/api/intents/#{proposed["id"]}/approve", %{"actor" => "human-reviewer"})

          approved = json_response(resp, 200)["data"]
          assert approved["state"] == "approved"

          # Step 4: Verify state via detail endpoint
          resp =
            conn
            |> authenticated()
            |> get("/api/intents/#{proposed["id"]}")

          detail = json_response(resp, 200)["data"]
          assert detail["state"] == "approved"
          assert [_ | _] = detail["transition_log"]
        end
      )
    end
  end
end
