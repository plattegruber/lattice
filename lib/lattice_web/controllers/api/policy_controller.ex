defmodule LatticeWeb.Api.PolicyController do
  @moduledoc """
  API controller for repo profile management.

  Provides CRUD endpoints for managing per-repo policy profiles.
  """

  use LatticeWeb, :controller

  alias Lattice.Policy.IntentHistory
  alias Lattice.Policy.RepoProfile
  alias Lattice.Policy.SpritePurpose

  @doc "GET /api/policy/profiles — list all repo profiles."
  def index(conn, _params) do
    {:ok, profiles} = RepoProfile.list()

    json(conn, %{
      data: Enum.map(profiles, &RepoProfile.to_map/1),
      timestamp: DateTime.utc_now()
    })
  end

  @doc "GET /api/policy/profiles/:repo — show a repo profile."
  def show(conn, %{"repo" => repo}) do
    repo = URI.decode(repo)

    case RepoProfile.get(repo) do
      {:ok, profile} ->
        json(conn, %{data: RepoProfile.to_map(profile), timestamp: DateTime.utc_now()})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Profile not found", code: "PROFILE_NOT_FOUND"})
    end
  end

  @doc "PUT /api/policy/profiles/:repo — create or update a repo profile."
  def upsert(conn, %{"repo" => repo} = params) do
    repo = URI.decode(repo)

    profile = %RepoProfile{
      repo: repo,
      test_commands: Map.get(params, "test_commands", []),
      branch_convention:
        Map.get(params, "branch_convention", %{"main" => "main", "pr_prefix" => ""}),
      ci_checks: Map.get(params, "ci_checks", []),
      risk_zones: Map.get(params, "risk_zones", []),
      doc_paths: Map.get(params, "doc_paths", []),
      auto_approve_paths: Map.get(params, "auto_approve_paths", []),
      settings: Map.get(params, "settings", %{})
    }

    :ok = RepoProfile.put(profile)

    conn
    |> put_status(:ok)
    |> json(%{data: RepoProfile.to_map(profile), timestamp: DateTime.utc_now()})
  end

  @doc "DELETE /api/policy/profiles/:repo — delete a repo profile."
  def delete(conn, %{"repo" => repo}) do
    repo = URI.decode(repo)
    :ok = RepoProfile.delete(repo)

    conn
    |> put_status(:ok)
    |> json(%{data: %{deleted: repo}, timestamp: DateTime.utc_now()})
  end

  # ── Sprite Purpose ────────────────────────────────────────────

  @doc "GET /api/policy/purposes — list all sprite purposes."
  def list_purposes(conn, _params) do
    {:ok, purposes} = SpritePurpose.list()

    json(conn, %{
      data: Enum.map(purposes, &SpritePurpose.to_map/1),
      timestamp: DateTime.utc_now()
    })
  end

  @doc "GET /api/policy/purposes/:name — get sprite purpose."
  def show_purpose(conn, %{"name" => name}) do
    case SpritePurpose.get(name) do
      {:ok, purpose} ->
        json(conn, %{data: SpritePurpose.to_map(purpose), timestamp: DateTime.utc_now()})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Purpose not found", code: "PURPOSE_NOT_FOUND"})
    end
  end

  @doc "PUT /api/policy/purposes/:name — set sprite purpose."
  def upsert_purpose(conn, %{"name" => name} = params) do
    purpose = %SpritePurpose{
      sprite_name: name,
      repo: Map.get(params, "repo"),
      task_kinds: Map.get(params, "task_kinds", []),
      labels: Map.get(params, "labels", []),
      notes: Map.get(params, "notes")
    }

    :ok = SpritePurpose.put(purpose)

    conn
    |> put_status(:ok)
    |> json(%{data: SpritePurpose.to_map(purpose), timestamp: DateTime.utc_now()})
  end

  # ── Intent History ────────────────────────────────────────────

  @doc "GET /api/policy/history — intent history summaries for all repos."
  def intent_history(conn, _params) do
    summaries = IntentHistory.all_repo_summaries()

    json(conn, %{data: summaries, timestamp: DateTime.utc_now()})
  end

  @doc "GET /api/policy/history/:repo — intent history for a specific repo."
  def repo_history(conn, %{"repo" => repo}) do
    repo = URI.decode(repo)
    summary = IntentHistory.repo_summary(repo)

    json(conn, %{data: summary, timestamp: DateTime.utc_now()})
  end
end
