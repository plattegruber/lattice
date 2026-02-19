defmodule LatticeWeb.Api.ProjectController do
  @moduledoc """
  Project API controller — manages projects and their decomposition.
  """

  use LatticeWeb, :controller

  alias Lattice.Projects.Project
  alias Lattice.Projects.Decomposer

  @doc "GET /api/projects — list all projects."
  def index(conn, _params) do
    {:ok, projects} = Project.list()

    json(conn, %{
      data: Enum.map(projects, &Project.to_map/1),
      timestamp: DateTime.utc_now()
    })
  end

  @doc "GET /api/projects/:id — show project detail."
  def show(conn, %{"id" => id}) do
    case Project.get(id) do
      {:ok, project} ->
        json(conn, %{data: Project.to_map(project), timestamp: DateTime.utc_now()})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Project not found", code: "PROJECT_NOT_FOUND"})
    end
  end

  @doc "POST /api/projects — create a project."
  def create(conn, params) do
    with {:ok, name} <- require_param(params, "name"),
         {:ok, description} <- require_param(params, "description") do
      opts = [
        repo: params["repo"],
        seed_issue_url: params["seed_issue_url"]
      ]

      {:ok, project} = Project.create(name, description, opts)

      conn
      |> put_status(:created)
      |> json(%{data: Project.to_map(project), timestamp: DateTime.utc_now()})
    else
      {:error, field} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Missing required field: #{field}", code: "MISSING_FIELD"})
    end
  end

  @doc "POST /api/projects/:id/decompose — decompose project into epics/tasks."
  def decompose(conn, %{"id" => id}) do
    case Project.get(id) do
      {:ok, project} ->
        epics = Decomposer.decompose(project.description, repo: project.repo)

        {:ok, updated} = Project.update(id, %{epics: epics})

        json(conn, %{
          data: Project.to_map(updated),
          epics_created: length(epics),
          timestamp: DateTime.utc_now()
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Project not found", code: "PROJECT_NOT_FOUND"})
    end
  end

  @doc "DELETE /api/projects/:id — delete a project."
  def delete(conn, %{"id" => id}) do
    case Project.get(id) do
      {:ok, _} ->
        Project.delete(id)
        json(conn, %{data: %{deleted: true}, timestamp: DateTime.utc_now()})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Project not found", code: "PROJECT_NOT_FOUND"})
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, key}
      "" -> {:error, key}
      value -> {:ok, value}
    end
  end
end
