defmodule LatticeWeb.Api.RunController do
  @moduledoc """
  API controller for querying Run entities.

  Provides read-only endpoints for listing and inspecting runs. Runs are
  created by the execution pipeline, not directly via the API.
  """

  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.Protocol.Answer
  alias Lattice.Runs.Run
  alias Lattice.Runs.Store, as: RunStore

  tags(["Runs"])
  security([%{"BearerAuth" => []}])

  @valid_statuses ~w(pending running succeeded failed canceled blocked blocked_waiting_for_user)

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
          enum: ["pending", "running", "succeeded", "failed", "canceled", "blocked", "blocked_waiting_for_user"]
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

  # ── POST /api/runs/:id/answer ─────────────────────────────────────

  operation(:answer,
    summary: "Answer a blocked run's question",
    description: "Provides an answer to resume a run blocked waiting for user input.",
    parameters: [
      id: [
        in: :path,
        type: :string,
        description: "Run identifier",
        required: true
      ]
    ],
    request_body:
      {"Answer payload", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           selected_choice: %OpenApiSpex.Schema{type: :string},
           free_text: %OpenApiSpex.Schema{type: :string}
         }
       }},
    responses: [
      ok: {"Run resumed", "application/json", nil},
      not_found: {"Not found", "application/json", nil},
      unprocessable_entity: {"Invalid transition", "application/json", nil},
      unauthorized: {"Unauthorized", "application/json", nil}
    ]
  )

  @doc """
  POST /api/runs/:id/answer -- provide an answer to resume a blocked run.
  """
  def answer(conn, %{"id" => run_id} = params) do
    with {:ok, run} <- RunStore.get(run_id),
         {:ok, answer} <- build_answer(params, run),
         {:ok, updated} <- Run.resume(run, answer),
         :ok <- RunStore.update(updated) do
      Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_resumed, updated})

      conn
      |> put_status(200)
      |> json(%{data: serialize_run(updated), timestamp: DateTime.utc_now()})
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Run not found", code: "RUN_NOT_FOUND"})

      {:error, {:invalid_transition, _, _}} ->
        conn
        |> put_status(422)
        |> json(%{error: "Run is not blocked", code: "INVALID_STATE_TRANSITION"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: "Failed: #{inspect(reason)}", code: "ANSWER_FAILED"})
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

  defp build_answer(params, run) do
    answer =
      Answer.new(%{
        question_prompt: get_in(run.question, [:prompt]) || get_in(run.question, ["prompt"]),
        selected_choice: params["selected_choice"],
        free_text: params["free_text"],
        answered_by: params["answered_by"] || "operator"
      })

    {:ok, answer}
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
      assumptions: run.assumptions,
      exit_code: run.exit_code,
      error: run.error,
      blocked_reason: run.blocked_reason,
      question: run.question,
      answer: run.answer,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end
end
