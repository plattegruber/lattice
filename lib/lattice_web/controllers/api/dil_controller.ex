defmodule LatticeWeb.Api.DilController do
  @moduledoc """
  API controller for ad-hoc Daily Improvement Loop runs.

  Triggers the DIL pipeline on demand, bypassing the cron schedule and
  the enabled/disabled gate. Other safety gates (open issue, cooldown,
  rejection cooldown) are still checked unless `skip_gates` is true.
  """

  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.DIL.Runner

  tags(["DIL"])
  security([%{"BearerAuth" => []}])

  operation(:run,
    summary: "Trigger DIL run",
    description:
      "Runs the Daily Improvement Loop ad-hoc. Pass `skip_gates: true` in the body to bypass safety gates.",
    request_body:
      {"DIL run options", "application/json",
       %OpenApiSpex.Schema{
         type: :object,
         properties: %{
           skip_gates: %OpenApiSpex.Schema{type: :boolean, default: false}
         }
       }, required: false},
    responses: [
      ok: {"DIL result", "application/json", %OpenApiSpex.Schema{type: :object}},
      unauthorized: {"Unauthorized", "application/json", LatticeWeb.Schemas.UnauthorizedResponse}
    ]
  )

  @doc """
  POST /api/dil/run — trigger an ad-hoc DIL run.
  """
  def run(conn, params) do
    skip_gates = params["skip_gates"] == true

    case Runner.run(skip_gates: skip_gates) do
      {:ok, :disabled} ->
        conn
        |> put_status(200)
        |> json(%{data: %{status: "disabled"}, timestamp: DateTime.utc_now()})

      {:ok, {:skipped, reason}} ->
        conn
        |> put_status(200)
        |> json(%{data: %{status: "skipped", reason: reason}, timestamp: DateTime.utc_now()})

      {:ok, {:no_candidate, summary}} ->
        conn
        |> put_status(200)
        |> json(%{data: Map.put(summary, :status, "no_candidate"), timestamp: DateTime.utc_now()})

      {:ok, {:candidate, summary}} ->
        conn
        |> put_status(200)
        |> json(%{data: Map.put(summary, :status, "candidate"), timestamp: DateTime.utc_now()})

      {:error, reason} ->
        conn
        |> put_status(500)
        |> json(%{error: "DIL run failed: #{inspect(reason)}", code: "DIL_ERROR"})
    end
  end
end
