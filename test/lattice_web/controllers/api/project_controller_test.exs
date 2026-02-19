defmodule LatticeWeb.Api.ProjectControllerTest do
  use LatticeWeb.ConnCase

  alias Lattice.Projects.Project

  @moduletag :unit

  setup do
    {:ok, projects} = Project.list()
    Enum.each(projects, fn p -> Project.delete(p.id) end)
    :ok
  end

  defp authenticated(conn) do
    put_req_header(conn, "authorization", "Bearer test-token")
  end

  describe "GET /api/projects" do
    test "lists projects", %{conn: conn} do
      Project.create("Test Project", "A test")

      conn =
        conn
        |> authenticated()
        |> get(~p"/api/projects")

      assert %{"data" => [project]} = json_response(conn, 200)
      assert project["name"] == "Test Project"
    end
  end

  describe "POST /api/projects" do
    test "creates a project", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post(~p"/api/projects", %{
          "name" => "New Project",
          "description" => "A new project",
          "repo" => "org/repo"
        })

      assert %{"data" => project} = json_response(conn, 201)
      assert project["name"] == "New Project"
      assert project["repo"] == "org/repo"
    end

    test "returns 422 when name missing", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> post(~p"/api/projects", %{"description" => "test"})

      assert %{"code" => "MISSING_FIELD"} = json_response(conn, 422)
    end
  end

  describe "GET /api/projects/:id" do
    test "shows project detail", %{conn: conn} do
      {:ok, project} = Project.create("Detail Test", "test")

      conn =
        conn
        |> authenticated()
        |> get(~p"/api/projects/#{project.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["name"] == "Detail Test"
      assert is_map(data["progress"])
    end

    test "returns 404 for nonexistent", %{conn: conn} do
      conn =
        conn
        |> authenticated()
        |> get(~p"/api/projects/nonexistent")

      assert %{"code" => "PROJECT_NOT_FOUND"} = json_response(conn, 404)
    end
  end

  describe "POST /api/projects/:id/decompose" do
    test "decomposes project into epics", %{conn: conn} do
      {:ok, project} =
        Project.create("Decompose Test", """
        ## Setup
        - [ ] Install deps
        - [ ] Configure DB

        ## Build
        - [ ] Create API
        """)

      conn =
        conn
        |> authenticated()
        |> post(~p"/api/projects/#{project.id}/decompose")

      assert %{"data" => data, "epics_created" => 2} = json_response(conn, 200)
      assert length(data["epics"]) == 2
    end
  end

  describe "DELETE /api/projects/:id" do
    test "deletes a project", %{conn: conn} do
      {:ok, project} = Project.create("Delete Test", "test")

      conn =
        conn
        |> authenticated()
        |> delete(~p"/api/projects/#{project.id}")

      assert %{"data" => %{"deleted" => true}} = json_response(conn, 200)
    end
  end
end
