defmodule LatticeWeb.Api.ArtifactControllerTest do
  use LatticeWeb.ConnCase

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.ArtifactLink
  alias Lattice.Capabilities.GitHub.ArtifactRegistry

  defp authenticated(conn) do
    put_req_header(conn, "authorization", "Bearer test-token")
  end

  # ── GET /api/intents/:id/artifacts ────────────────────────────────

  describe "GET /api/intents/:id/artifacts" do
    test "returns empty list when no artifacts registered", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/intents/int_no_artifacts/artifacts")

      assert json_response(conn, 200)["data"] == []
    end

    test "returns registered artifacts for intent", %{conn: conn} do
      link =
        ArtifactLink.new(%{
          intent_id: "int_api_test_1",
          kind: :issue,
          ref: 42,
          role: :governance,
          url: "https://github.com/owner/repo/issues/42"
        })

      ArtifactRegistry.register(link)

      conn =
        conn
        |> authenticated()
        |> get("/api/intents/int_api_test_1/artifacts")

      response = json_response(conn, 200)
      assert length(response["data"]) == 1
      [artifact] = response["data"]
      assert artifact["intent_id"] == "int_api_test_1"
      assert artifact["kind"] == "issue"
      assert artifact["ref"] == 42
      assert artifact["role"] == "governance"
      assert artifact["url"] == "https://github.com/owner/repo/issues/42"
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/intents/int_test/artifacts")
      assert json_response(conn, 401)
    end
  end

  # ── GET /api/github/lookup ────────────────────────────────────────

  describe "GET /api/github/lookup" do
    test "reverse lookup by kind and ref", %{conn: conn} do
      link =
        ArtifactLink.new(%{
          intent_id: "int_lookup_test_1",
          kind: :pull_request,
          ref: 99,
          role: :output,
          url: "https://github.com/owner/repo/pull/99"
        })

      ArtifactRegistry.register(link)

      conn =
        conn
        |> authenticated()
        |> get("/api/github/lookup", %{kind: "pull_request", ref: "99"})

      response = json_response(conn, 200)
      assert Enum.any?(response["data"], &(&1["intent_id"] == "int_lookup_test_1"))
    end

    test "returns empty for unknown ref", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/github/lookup", %{kind: "issue", ref: "999888"})

      assert json_response(conn, 200)["data"] == []
    end

    test "returns 422 for invalid kind", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/github/lookup", %{kind: "invalid", ref: "1"})

      response = json_response(conn, 422)
      assert response["code"] == "INVALID_KIND"
    end

    test "returns 422 when missing params", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get("/api/github/lookup")

      response = json_response(conn, 422)
      assert response["code"] == "MISSING_FIELD"
    end

    test "supports branch lookup by name", %{conn: conn} do
      link =
        ArtifactLink.new(%{
          intent_id: "int_branch_lookup",
          kind: :branch,
          ref: "feat/test-branch",
          role: :output
        })

      ArtifactRegistry.register(link)

      conn =
        conn
        |> authenticated()
        |> get("/api/github/lookup", %{kind: "branch", ref: "feat/test-branch"})

      response = json_response(conn, 200)
      assert Enum.any?(response["data"], &(&1["intent_id"] == "int_branch_lookup"))
    end
  end
end
