defmodule LatticeWeb.Api.SpriteController do
  @moduledoc """
  API controller for individual sprite operations.

  Provides endpoints for listing sprites, querying sprite details,
  updating desired state, and triggering single-sprite reconciliation.
  """

  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.Capabilities.Sprites, as: SpritesCapability
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

  operation(:create,
    summary: "Create a sprite",
    description:
      "Creates a new sprite via the Sprites API and starts a GenServer for it in the fleet.",
    request_body:
      {"Create sprite request", "application/json", LatticeWeb.Schemas.CreateSpriteRequest},
    responses: [
      ok: {"Created sprite", "application/json", LatticeWeb.Schemas.SpriteDetailResponse},
      unprocessable_entity:
        {"Validation error", "application/json", LatticeWeb.Schemas.ErrorResponse},
      bad_gateway: {"Upstream API error", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  POST /api/sprites — create a new sprite.

  Body: `{ "name": "my-sprite" }`
  """
  def create(conn, %{"name" => name}) when is_binary(name) and name != "" do
    with {:ok, sprite_data} <- create_upstream_sprite(name),
         sprite_id = extract_sprite_id(sprite_data, name),
         {:ok, ^sprite_id} <- add_to_fleet(sprite_id) do
      render_created_sprite(conn, sprite_id)
    else
      {:error, :already_exists} ->
        conn
        |> put_status(422)
        |> json(%{error: "Sprite already exists", code: "SPRITE_ALREADY_EXISTS"})

      {:error, reason} ->
        conn
        |> put_status(502)
        |> json(%{error: "Upstream API error: #{inspect(reason)}", code: "UPSTREAM_API_ERROR"})
    end
  end

  def create(conn, %{"name" => ""}) do
    conn
    |> put_status(422)
    |> json(%{error: "Missing required field: name", code: "MISSING_FIELD"})
  end

  def create(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "Missing required field: name", code: "MISSING_FIELD"})
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

  operation(:delete,
    summary: "Delete a sprite",
    description:
      "Deletes a sprite from the Sprites API and removes it from the local fleet. This is a dangerous operation.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Sprite identifier",
        required: true
      ]
    ],
    responses: [
      ok: {"Deleted sprite", "application/json", LatticeWeb.Schemas.DeleteSpriteResponse},
      not_found: {"Not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      internal_server_error:
        {"Server error", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  DELETE /api/sprites/:id — delete a sprite.

  Deletes the sprite from the upstream Sprites API first (source of truth),
  then removes it from the local fleet manager.
  """
  def delete(conn, %{"id" => id}) do
    case SpritesCapability.delete_sprite(id) do
      :ok ->
        FleetManager.remove_sprite(id)

        conn
        |> put_status(200)
        |> json(%{data: %{id: id, deleted: true}, timestamp: DateTime.utc_now()})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{
          error: "Failed to delete sprite: #{inspect(reason)}",
          code: "DELETE_FAILED"
        })
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp create_upstream_sprite(name) do
    SpritesCapability.create_sprite(name)
  end

  defp extract_sprite_id(sprite_data, fallback_name) do
    Map.get(sprite_data, :id) || Map.get(sprite_data, "id") || fallback_name
  end

  defp add_to_fleet(sprite_id) do
    FleetManager.add_sprite(sprite_id)
  end

  defp render_created_sprite(conn, sprite_id) do
    data =
      case get_sprite_state(sprite_id) do
        {:ok, state} ->
          serialize_sprite_detail(sprite_id, state)

        {:error, :not_found} ->
          %{
            id: sprite_id,
            observed_state: :hibernating,
            desired_state: :hibernating,
            health: :unknown
          }
      end

    conn
    |> put_status(200)
    |> json(%{data: data, timestamp: DateTime.utc_now()})
  end

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
