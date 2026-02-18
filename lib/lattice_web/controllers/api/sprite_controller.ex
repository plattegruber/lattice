defmodule LatticeWeb.Api.SpriteController do
  @moduledoc """
  API controller for individual sprite operations.

  Provides endpoints for listing sprites, querying sprite details,
  wake/sleep commands, and triggering single-sprite observation.
  """

  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.Capabilities.Sprites, as: SpritesCapability
  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.Sprite
  alias Lattice.Sprites.State

  tags(["Sprites"])
  security([%{"BearerAuth" => []}])

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

  operation(:wake,
    summary: "Wake a sprite",
    description: "Sends a wake command to the Sprites API for this sprite.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Sprite identifier",
        required: true
      ]
    ],
    responses: [
      ok: {"Sprite woken", "application/json", LatticeWeb.Schemas.SpriteDetailResponse},
      not_found: {"Not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unprocessable_entity: {"API error", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  POST /api/sprites/:id/wake — wake a sprite.
  """
  def wake(conn, %{"id" => sprite_id}) do
    with {:ok, _pid} <- FleetManager.get_sprite_pid(sprite_id),
         {:ok, _} <- SpritesCapability.wake(sprite_id) do
      # Give the observation loop a moment, then return current state
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
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Failed to wake sprite: #{inspect(reason)}",
          code: "INVALID_STATE_TRANSITION"
        })
    end
  end

  operation(:sleep,
    summary: "Sleep a sprite",
    description: "Sends a sleep command to the Sprites API for this sprite.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Sprite identifier",
        required: true
      ]
    ],
    responses: [
      ok: {"Sprite sleeping", "application/json", LatticeWeb.Schemas.SpriteDetailResponse},
      not_found: {"Not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unprocessable_entity: {"API error", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  POST /api/sprites/:id/sleep — sleep a sprite.
  """
  def sleep(conn, %{"id" => sprite_id}) do
    with {:ok, _pid} <- FleetManager.get_sprite_pid(sprite_id),
         {:ok, _} <- SpritesCapability.sleep(sprite_id) do
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
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Failed to sleep sprite: #{inspect(reason)}",
          code: "INVALID_STATE_TRANSITION"
        })
    end
  end

  operation(:reconcile,
    summary: "Trigger sprite observation",
    description: "Triggers an immediate observation cycle for a single sprite.",
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
        {"Observation triggered", "application/json",
         LatticeWeb.Schemas.ReconcileTriggeredResponse},
      not_found: {"Not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  POST /api/sprites/:id/reconcile — trigger observation for a single sprite.
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

  operation(:update_tags,
    summary: "Update sprite tags",
    description:
      "Merges the provided tags into the sprite's existing tags. Tags are Lattice-local metadata.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Sprite identifier",
        required: true
      ]
    ],
    request_body:
      {"Update tags request", "application/json", LatticeWeb.Schemas.UpdateTagsRequest},
    responses: [
      ok: {"Updated tags", "application/json", LatticeWeb.Schemas.UpdateTagsResponse},
      not_found: {"Not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unprocessable_entity:
        {"Validation error", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  PUT /api/sprites/:id/tags — update tags for a sprite.

  Body: `{ "tags": { "env": "prod", "purpose": "ci" } }`

  Merges the provided tags with existing tags and persists to the store.
  """
  def update_tags(conn, %{"id" => id, "tags" => tags}) when is_map(tags) do
    case validate_tags(tags) do
      :ok ->
        with {:ok, state} <- get_sprite_state(id),
             merged = Map.merge(state.tags || %{}, tags),
             {:ok, pid} <- FleetManager.get_sprite_pid(id),
             :ok <- Sprite.set_tags(pid, merged) do
          Lattice.Store.put(:sprite_metadata, id, %{
            tags: merged
          })

          conn
          |> put_status(200)
          |> json(%{data: %{id: id, tags: merged}, timestamp: DateTime.utc_now()})
        else
          {:error, :not_found} ->
            conn
            |> put_status(404)
            |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})

          {:error, reason} ->
            conn
            |> put_status(500)
            |> json(%{error: "Failed to update tags: #{inspect(reason)}", code: "UPDATE_FAILED"})
        end

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: reason, code: "INVALID_TAGS"})
    end
  end

  def update_tags(conn, %{"id" => _id}) do
    conn
    |> put_status(422)
    |> json(%{error: "Missing required field: tags", code: "MISSING_FIELD"})
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
            status: :cold
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
      status: state.status
    }
  end

  defp serialize_sprite_detail(id, %State{} = state) do
    %{
      id: id,
      status: state.status,
      failure_count: state.failure_count,
      last_observed_at: state.last_observed_at,
      started_at: state.started_at,
      updated_at: state.updated_at,
      tags: state.tags || %{}
    }
  end

  @max_tag_key_length 64
  @max_tag_value_length 256
  @max_tags_count 50

  defp validate_tags(tags) when map_size(tags) > @max_tags_count do
    {:error, "Too many tags (max #{@max_tags_count})"}
  end

  defp validate_tags(tags) do
    Enum.reduce_while(tags, :ok, fn {key, value}, :ok ->
      cond do
        not is_binary(key) ->
          {:halt, {:error, "Tag keys must be strings"}}

        not is_binary(value) ->
          {:halt, {:error, "Tag values must be strings"}}

        byte_size(key) > @max_tag_key_length ->
          {:halt, {:error, "Tag key too long (max #{@max_tag_key_length} bytes)"}}

        byte_size(value) > @max_tag_value_length ->
          {:halt, {:error, "Tag value too long (max #{@max_tag_value_length} bytes)"}}

        true ->
          {:cont, :ok}
      end
    end)
  end
end
