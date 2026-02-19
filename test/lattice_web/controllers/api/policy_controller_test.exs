defmodule LatticeWeb.Api.PolicyControllerTest do
  use LatticeWeb.ConnCase

  @moduletag :unit

  alias Lattice.Policy.RepoProfile

  setup do
    # Clean up test profiles
    {:ok, profiles} = RepoProfile.list()

    for p <- profiles, String.starts_with?(p.repo || "", "test/") do
      RepoProfile.delete(p.repo)
    end

    :ok
  end

  defp authenticated(conn) do
    put_req_header(conn, "authorization", "Bearer test-token")
  end

  describe "GET /api/policy/profiles" do
    test "lists all profiles", %{conn: conn} do
      RepoProfile.put(%RepoProfile{repo: "test/api-list-a"})
      RepoProfile.put(%RepoProfile{repo: "test/api-list-b"})

      conn = conn |> authenticated() |> get("/api/policy/profiles")
      assert %{"data" => profiles} = json_response(conn, 200)
      repos = Enum.map(profiles, & &1["repo"])
      assert "test/api-list-a" in repos
      assert "test/api-list-b" in repos
    after
      RepoProfile.delete("test/api-list-a")
      RepoProfile.delete("test/api-list-b")
    end
  end

  describe "GET /api/policy/profiles/:repo" do
    test "returns profile for known repo", %{conn: conn} do
      RepoProfile.put(%RepoProfile{
        repo: "test/api-show",
        test_commands: ["mix test"],
        risk_zones: ["lib/safety/"]
      })

      conn =
        conn
        |> authenticated()
        |> get("/api/policy/profiles/#{URI.encode("test/api-show", &URI.char_unreserved?/1)}")

      assert %{"data" => profile} = json_response(conn, 200)
      assert profile["repo"] == "test/api-show"
      assert profile["test_commands"] == ["mix test"]
      assert profile["risk_zones"] == ["lib/safety/"]
    after
      RepoProfile.delete("test/api-show")
    end

    test "returns 404 for unknown repo", %{conn: conn} do
      conn = conn |> authenticated() |> get("/api/policy/profiles/test%2Fno-such")
      assert json_response(conn, 404)["code"] == "PROFILE_NOT_FOUND"
    end
  end

  describe "PUT /api/policy/profiles/:repo" do
    test "creates a new profile", %{conn: conn} do
      body = %{
        "test_commands" => ["npm test"],
        "ci_checks" => ["build"],
        "risk_zones" => ["src/auth/"]
      }

      conn =
        conn
        |> authenticated()
        |> put(
          "/api/policy/profiles/#{URI.encode("test/api-create", &URI.char_unreserved?/1)}",
          body
        )

      assert %{"data" => profile} = json_response(conn, 200)
      assert profile["repo"] == "test/api-create"
      assert profile["test_commands"] == ["npm test"]

      # Verify persisted
      assert {:ok, stored} = RepoProfile.get("test/api-create")
      assert stored.test_commands == ["npm test"]
    after
      RepoProfile.delete("test/api-create")
    end

    test "updates an existing profile", %{conn: conn} do
      RepoProfile.put(%RepoProfile{repo: "test/api-update", test_commands: ["old"]})

      body = %{"test_commands" => ["new"]}

      conn =
        conn
        |> authenticated()
        |> put(
          "/api/policy/profiles/#{URI.encode("test/api-update", &URI.char_unreserved?/1)}",
          body
        )

      assert %{"data" => profile} = json_response(conn, 200)
      assert profile["test_commands"] == ["new"]
    after
      RepoProfile.delete("test/api-update")
    end
  end

  describe "DELETE /api/policy/profiles/:repo" do
    test "deletes a profile", %{conn: conn} do
      RepoProfile.put(%RepoProfile{repo: "test/api-delete"})

      conn =
        conn
        |> authenticated()
        |> delete(
          "/api/policy/profiles/#{URI.encode("test/api-delete", &URI.char_unreserved?/1)}"
        )

      assert %{"data" => %{"deleted" => "test/api-delete"}} = json_response(conn, 200)
      assert {:error, :not_found} = RepoProfile.get("test/api-delete")
    end
  end

  describe "authentication" do
    test "rejects unauthenticated requests", %{conn: conn} do
      conn = get(conn, "/api/policy/profiles")
      assert json_response(conn, 401)
    end
  end
end
