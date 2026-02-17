defmodule LatticeWeb.Api.TaskController do
  @moduledoc """
  API controller for assigning tasks to sprites.

  Provides the `POST /api/sprites/:name/tasks` endpoint which builds a Task
  intent from the request body, validates that the target sprite exists, and
  feeds it through the intent pipeline (classify -> gate -> approve/await).
  """

  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Sprites.FleetManager

  tags(["Tasks"])
  security([%{"BearerAuth" => []}])

  @source %{type: :operator, id: "api"}

  operation(:create,
    summary: "Assign a task to a sprite",
    description:
      "Creates a Task intent for the given sprite and feeds it through the classify-gate pipeline. " <>
        "Safe or allowlisted tasks auto-approve; others await human approval.",
    parameters: [
      name: [
        in: :path,
        type: :string,
        description: "Sprite name",
        required: true
      ]
    ],
    request_body:
      {"Task assignment request", "application/json", LatticeWeb.Schemas.CreateTaskRequest},
    responses: [
      ok: {"Created task intent", "application/json", LatticeWeb.Schemas.TaskIntentResponse},
      not_found: {"Sprite not found", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unprocessable_entity:
        {"Validation error", "application/json", LatticeWeb.Schemas.ErrorResponse},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  POST /api/sprites/:name/tasks -- assign a task to a sprite.

  Validates the sprite exists, builds a Task intent via `Intent.new_task/4`,
  and proposes it through `Pipeline.propose/1`.
  """
  def create(conn, %{"name" => sprite_name} = params) do
    with {:sprite, {:ok, _pid}} <- {:sprite, FleetManager.get_sprite_pid(sprite_name)},
         {:validate, :ok} <- {:validate, validate_required_fields(params)},
         {:intent, {:ok, intent}} <- {:intent, build_task_intent(sprite_name, params)},
         {:pipeline, {:ok, result}} <- {:pipeline, Pipeline.propose(intent)} do
      conn
      |> put_status(200)
      |> json(%{
        data: serialize_task_intent(result, sprite_name),
        timestamp: DateTime.utc_now()
      })
    else
      {:sprite, {:error, :not_found}} ->
        conn
        |> put_status(404)
        |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})

      {:validate, {:error, {:missing_field, field}}} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Missing required field: #{field}",
          code: "MISSING_FIELD"
        })

      {:intent, {:error, {:missing_field, field}}} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Missing required field: #{field}",
          code: "MISSING_FIELD"
        })

      {:pipeline, {:error, reason}} ->
        conn
        |> put_status(422)
        |> json(%{
          error: "Failed to create task: #{inspect(reason)}",
          code: "PIPELINE_ERROR"
        })
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp validate_required_fields(params) do
    cond do
      not is_binary(Map.get(params, "repo")) or Map.get(params, "repo") == "" ->
        {:error, {:missing_field, :repo}}

      not is_binary(Map.get(params, "task_kind")) or Map.get(params, "task_kind") == "" ->
        {:error, {:missing_field, :task_kind}}

      not is_binary(Map.get(params, "instructions")) or Map.get(params, "instructions") == "" ->
        {:error, {:missing_field, :instructions}}

      true ->
        :ok
    end
  end

  defp build_task_intent(sprite_name, params) do
    opts =
      [
        task_kind: Map.fetch!(params, "task_kind"),
        instructions: Map.fetch!(params, "instructions")
      ]
      |> maybe_add_opt(:base_branch, Map.get(params, "base_branch"))
      |> maybe_add_opt(:pr_title, Map.get(params, "pr_title"))
      |> maybe_add_opt(:pr_body, Map.get(params, "pr_body"))
      |> maybe_add_opt(:summary, Map.get(params, "summary"))

    Intent.new_task(@source, sprite_name, Map.fetch!(params, "repo"), opts)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp serialize_task_intent(%Intent{} = intent, sprite_name) do
    %{
      intent_id: intent.id,
      state: intent.state,
      classification: intent.classification,
      sprite_name: sprite_name,
      repo: Map.get(intent.payload, "repo")
    }
  end
end
