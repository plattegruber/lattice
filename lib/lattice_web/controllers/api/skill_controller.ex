defmodule LatticeWeb.Api.SkillController do
  @moduledoc """
  API controller for sprite skill discovery and inspection.

  Provides endpoints for listing and inspecting skill manifests
  discovered on sprites. Skills are self-describing units of work
  found at `/skills/*/skill.json` on each sprite's filesystem.
  """

  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.Protocol.SkillDiscovery
  alias Lattice.Sprites.FleetManager

  tags(["Skills"])
  security([%{"BearerAuth" => []}])

  operation(:index,
    summary: "List available skills for a sprite",
    description:
      "Discovers and returns skill manifests for the given sprite. " <>
        "Results are cached; a cold cache triggers on-demand discovery via exec.",
    parameters: [
      name: [
        in: :path,
        type: :string,
        description: "Sprite name",
        required: true
      ]
    ],
    responses: [
      ok: {"List of skill manifests", "application/json", LatticeWeb.Schemas.SkillListResponse},
      not_found: {"Sprite not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  GET /api/sprites/:name/skills -- list available skills for a sprite.
  """
  def index(conn, %{"name" => sprite_name}) do
    case FleetManager.get_sprite_pid(sprite_name) do
      {:ok, _pid} ->
        {:ok, skills} = SkillDiscovery.discover(sprite_name)

        conn
        |> put_status(200)
        |> json(%{
          data: Enum.map(skills, &serialize_skill_summary/1),
          timestamp: DateTime.utc_now()
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})
    end
  end

  operation(:show,
    summary: "Get skill detail for a sprite",
    description: "Returns the full skill manifest including inputs, outputs, and permissions.",
    parameters: [
      name: [
        in: :path,
        type: :string,
        description: "Sprite name",
        required: true
      ],
      skill_name: [
        in: :path,
        type: :string,
        description: "Skill name",
        required: true
      ]
    ],
    responses: [
      ok: {"Skill manifest detail", "application/json", LatticeWeb.Schemas.SkillDetailResponse},
      not_found:
        {"Sprite or skill not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  GET /api/sprites/:name/skills/:skill_name -- get skill detail.
  """
  def show(conn, %{"name" => sprite_name, "skill_name" => skill_name}) do
    with {:sprite, {:ok, _pid}} <- {:sprite, FleetManager.get_sprite_pid(sprite_name)},
         {:skill, {:ok, manifest}} <- {:skill, SkillDiscovery.get_skill(sprite_name, skill_name)} do
      conn
      |> put_status(200)
      |> json(%{
        data: serialize_skill_detail(manifest),
        timestamp: DateTime.utc_now()
      })
    else
      {:sprite, {:error, :not_found}} ->
        conn
        |> put_status(404)
        |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})

      {:skill, {:error, :not_found}} ->
        conn
        |> put_status(404)
        |> json(%{error: "Skill not found", code: "SKILL_NOT_FOUND"})
    end
  end

  # ── Serialization ──────────────────────────────────────────────────

  defp serialize_skill_summary(manifest) do
    %{
      name: manifest.name,
      description: manifest.description,
      input_count: length(manifest.inputs),
      output_count: length(manifest.outputs),
      permissions: manifest.permissions,
      produces_events: manifest.produces_events
    }
  end

  defp serialize_skill_detail(manifest) do
    %{
      name: manifest.name,
      description: manifest.description,
      inputs: Enum.map(manifest.inputs, &serialize_input/1),
      outputs: Enum.map(manifest.outputs, &serialize_output/1),
      permissions: manifest.permissions,
      produces_events: manifest.produces_events
    }
  end

  defp serialize_input(input) do
    %{
      name: input.name,
      type: to_string(input.type),
      required: input.required,
      description: input.description,
      default: input.default
    }
  end

  defp serialize_output(output) do
    %{
      name: output.name,
      type: output.type,
      description: output.description
    }
  end
end
