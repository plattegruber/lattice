defmodule LatticeWeb.Api.SpriteController do
  @moduledoc """
  API controller for individual sprite operations.

  Provides endpoints for listing sprites, querying sprite details,
  updating desired state, and triggering single-sprite reconciliation.
  """

  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.Sprite
  alias Lattice.Sprites.State

  tags(["Sprites"])
  security([%{"BearerAuth" => []}])

  @allowed_desired_states ~w(ready hibernating)

  operation(:index,
    summary: "List sprites",
    description: "Returns all sprites in the fleet with their current state.",
    responses: [
      ok: {"Sprite list", "application/json", LatticeWeb.Schemas.SpriteListResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  GET /api/sprites — list all sprites with current state.
  """
  def index(conn, _params) do
    sprites = FleetManager.list_sprites()

    conn
    |> put_status(200)
    |> json(%{
      data: Enum.map(sprites, fn {id, state} -> serialize_sprite(id, state) end),
      timestamp: DateTime.utc_now()
    })
  end

  operation(:show,
    summary: "Get sprite detail",
    description:
      "Returns full detail for a single sprite including timestamps and failure count.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Sprite identifier",
        required: true
      ]
    ],
    responses: [
      ok: {"Sprite detail", "application/json", LatticeWeb.Schemas.SpriteDetailResponse},
      not_found: {"Not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  GET /api/sprites/:id — single sprite detail.
  """
  def show(conn, %{"id" => sprite_id}) do
    case get_sprite_state(sprite_id) do
      {:ok, state} ->
        conn
        |> put_status(200)
        |> json(%{
          data: serialize_sprite_detail(sprite_id, state),
          timestamp: DateTime.utc_now()
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})
    end
  end

  operation(:update_desired,
    summary: "Update desired state",
    description:
      "Sets the desired state for a sprite. The reconciliation loop will work to converge.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Sprite identifier",
        required: true
      ]
    ],
    request_body:
      {"Desired state", "application/json", LatticeWeb.Schemas.UpdateDesiredStateRequest},
    responses: [
      ok: {"Updated sprite", "application/json", LatticeWeb.Schemas.SpriteDetailResponse},
      not_found: {"Not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unprocessable_entity:
        {"Validation error", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  PUT /api/sprites/:id/desired — update desired state for a sprite.

  Body: `{ "state": "ready" | "hibernating" }`
  """
  def update_desired(conn, %{"id" => sprite_id, "state" => desired_state_str})
      when desired_state_str in @allowed_desired_states do
    desired_state = String.to_existing_atom(desired_state_str)

    with {:ok, pid} <- FleetManager.get_sprite_pid(sprite_id),
         :ok <- Sprite.set_desired_state(pid, desired_state) do
      {:ok, updated_state} = Sprite.get_state(pid)

      conn
      |> put_status(200)
      |> json(%{
        data: serialize_sprite_detail(sprite_id, updated_state),
        timestamp: DateTime.utc_now()
      })
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})

      {:error, {:invalid_lifecycle, _}} ->
        conn
        |> put_status(422)
        |> json(%{error: "Invalid state transition", code: "INVALID_STATE_TRANSITION"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Failed to update desired state: #{inspect(reason)}",
          code: "INVALID_STATE_TRANSITION"
        })
    end
  end

  def update_desired(conn, %{"id" => _sprite_id, "state" => invalid_state}) do
    conn
    |> put_status(422)
    |> json(%{
      error:
        "Invalid desired state: #{inspect(invalid_state)}. Allowed: #{inspect(@allowed_desired_states)}",
      code: "INVALID_STATE"
    })
  end

  def update_desired(conn, %{"id" => _sprite_id}) do
    conn
    |> put_status(422)
    |> json(%{
      error: "Missing required field: state",
      code: "MISSING_FIELD"
    })
  end

  operation(:reconcile,
    summary: "Trigger sprite reconciliation",
    description: "Triggers an immediate reconciliation cycle for a single sprite.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Sprite identifier",
        required: true
      ]
    ],
    responses: [
      ok:
        {"Reconciliation triggered", "application/json",
         LatticeWeb.Schemas.ReconcileTriggeredResponse},
      not_found: {"Not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  POST /api/sprites/:id/reconcile — trigger reconciliation for a single sprite.
  """
  def reconcile(conn, %{"id" => sprite_id}) do
    case FleetManager.get_sprite_pid(sprite_id) do
      {:ok, pid} ->
        Sprite.reconcile_now(pid)

        conn
        |> put_status(200)
        |> json(%{
          data: %{sprite_id: sprite_id, status: "reconciliation_triggered"},
          timestamp: DateTime.utc_now()
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp get_sprite_state(sprite_id) do
    case FleetManager.get_sprite_pid(sprite_id) do
      {:ok, pid} -> Sprite.get_state(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp serialize_sprite(id, %State{} = state) do
    %{
      id: id,
      observed_state: state.observed_state,
      desired_state: state.desired_state,
      health: state.health
    }
  end

  defp serialize_sprite_detail(id, %State{} = state) do
    %{
      id: id,
      observed_state: state.observed_state,
      desired_state: state.desired_state,
      health: state.health,
      failure_count: state.failure_count,
      last_observed_at: state.last_observed_at,
      started_at: state.started_at,
      updated_at: state.updated_at
    }
  end
end
