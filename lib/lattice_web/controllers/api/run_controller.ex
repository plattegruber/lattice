defmodule LatticeWeb.Api.RunController do
  @moduledoc """
  API controller for querying Run entities.

  Provides read-only endpoints for listing and inspecting runs. Runs are
  created by the execution pipeline, not directly via the API.
  """

  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.Runs.Run
  alias Lattice.Runs.Store, as: RunStore

  tags(["Runs"])
  security([%{"BearerAuth" => []}])

  @valid_statuses ~w(pending running succeeded failed canceled)

  # ── GET /api/runs ───────────────────────────────────────────────────

  operation(:index,
    summary: "List runs",
    description: "Returns runs with optional filters by intent_id, sprite_name, and status.",
    parameters: [
      intent_id: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :string},
        description: "Filter by associated intent ID",
        required: false
      ],
      sprite_name: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :string},
        description: "Filter by sprite name",
        required: false
      ],
      status: [
        in: :query,
        schema: %OpenApiSpex.Schema{
          type: :string,
          enum: ["pending", "running", "succeeded", "failed", "canceled"]
        },
        description: "Filter by run status",
        required: false
      ]
    ],
    responses: [
      ok: {"Run list", "application/json", nil},
      unauthorized: {"Unauthorized", "application/json", nil}
    ]
  )

  @doc """
  GET /api/runs -- list runs with optional filters.

  Query params: `intent_id`, `sprite_name`, `status`
  """
  def index(conn, params) do
    filters = build_filters(params)
    {:ok, runs} = RunStore.list(filters)

    conn
    |> put_status(200)
    |> json(%{data: Enum.map(runs, &serialize_run/1), timestamp: DateTime.utc_now()})
  end

  # ── GET /api/runs/:id ──────────────────────────────────────────────

  operation(:show,
    summary: "Get run detail",
    description: "Returns full run detail including artifacts and timing.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Run identifier",
        required: true
      ]
    ],
    responses: [
      ok: {"Run detail", "application/json", nil},
      not_found: {"Not found", "application/json", nil},
      unauthorized: {"Unauthorized", "application/json", nil}
    ]
  )

  @doc """
  GET /api/runs/:id -- run detail.
  """
  def show(conn, %{"id" => run_id}) do
    case RunStore.get(run_id) do
      {:ok, run} ->
        conn
        |> put_status(200)
        |> json(%{data: serialize_run(run), timestamp: DateTime.utc_now()})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Run not found", code: "RUN_NOT_FOUND"})
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp build_filters(params) do
    params
    |> Enum.reduce(%{}, fn
      {"intent_id", v}, acc ->
        Map.put(acc, :intent_id, v)

      {"sprite_name", v}, acc ->
        Map.put(acc, :sprite_name, v)

      {"status", v}, acc when v in @valid_statuses ->
        Map.put(acc, :status, String.to_existing_atom(v))

      _, acc ->
        acc
    end)
  end

  defp serialize_run(%Run{} = run) do
    %{
      id: run.id,
      intent_id: run.intent_id,
      sprite_name: run.sprite_name,
      command: run.command,
      mode: run.mode,
      status: run.status,
      started_at: run.started_at,
      finished_at: run.finished_at,
      artifacts: run.artifacts,
      exit_code: run.exit_code,
      error: run.error,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end
end
