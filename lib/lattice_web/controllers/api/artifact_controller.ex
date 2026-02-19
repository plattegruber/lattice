defmodule LatticeWeb.Api.ArtifactController do
  @moduledoc """
  API controller for GitHub artifact link lookups.

  Provides forward lookups (intent → artifacts) and reverse lookups
  (GitHub ref → intents).
  """

  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.Capabilities.GitHub.ArtifactRegistry

  tags(["Artifacts"])
  security([%{"BearerAuth" => []}])

  # ── GET /api/intents/:id/artifacts ───────────────────────────────

  operation(:index,
    summary: "List artifacts for an intent",
    description: "Returns all GitHub artifact links associated with the given intent.",
    parameters: [
      id: [
        in: :path,
        schema: %OpenApiSpex.Schema{type: :string},
        description: "Intent ID",
        required: true
      ]
    ],
    responses: [
      ok:
        {"Artifact list", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array},
             timestamp: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
           }
         }}
    ]
  )

  def index(conn, %{"id" => intent_id}) do
    links = ArtifactRegistry.lookup_by_intent(intent_id)

    conn
    |> put_status(200)
    |> json(%{data: Enum.map(links, &serialize_link/1), timestamp: DateTime.utc_now()})
  end

  # ── GET /api/github/lookup ───────────────────────────────────────

  operation(:lookup,
    summary: "Reverse lookup GitHub artifact",
    description: "Given a GitHub entity kind and ref, returns all intents linked to it.",
    parameters: [
      kind: [
        in: :query,
        schema: %OpenApiSpex.Schema{
          type: :string,
          enum: ["issue", "pull_request", "branch", "commit"]
        },
        description: "GitHub entity kind",
        required: true
      ],
      ref: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :string},
        description: "GitHub reference (issue number, PR number, branch name, commit SHA)",
        required: true
      ]
    ],
    responses: [
      ok:
        {"Artifact links", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             data: %OpenApiSpex.Schema{type: :array},
             timestamp: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
           }
         }},
      unprocessable_entity:
        {"Invalid kind", "application/json",
         %OpenApiSpex.Schema{
           type: :object,
           properties: %{
             error: %OpenApiSpex.Schema{type: :string},
             code: %OpenApiSpex.Schema{type: :string}
           }
         }}
    ]
  )

  @valid_kinds ~w(issue pull_request branch commit)

  def lookup(conn, %{"kind" => kind_str, "ref" => ref_str}) when kind_str in @valid_kinds do
    kind = String.to_existing_atom(kind_str)
    ref = parse_ref(ref_str)

    links = ArtifactRegistry.lookup_by_ref(kind, ref)

    conn
    |> put_status(200)
    |> json(%{data: Enum.map(links, &serialize_link/1), timestamp: DateTime.utc_now()})
  end

  def lookup(conn, %{"kind" => kind}) do
    conn
    |> put_status(422)
    |> json(%{error: "Invalid kind: #{kind}", code: "INVALID_KIND"})
  end

  def lookup(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "Missing required parameters: kind, ref", code: "MISSING_FIELD"})
  end

  # ── Private ──────────────────────────────────────────────────────

  defp serialize_link(link) do
    %{
      intent_id: link.intent_id,
      run_id: link.run_id,
      kind: link.kind,
      ref: link.ref,
      url: link.url,
      role: link.role,
      created_at: link.created_at
    }
  end

  defp parse_ref(ref_str) do
    case Integer.parse(ref_str) do
      {number, ""} -> number
      _ -> ref_str
    end
  end
end
