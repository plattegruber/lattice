defmodule Mix.Tasks.Lattice.Audit do
  @shortdoc "Run a fleet-wide audit and exit"

  @moduledoc """
  Boots the Lattice application in minimal mode, triggers a fleet-wide
  reconciliation audit, logs the results, and exits.

  Designed for use as a Fly Scheduled Machine one-off command:

      fly machines run . --command "/app/bin/lattice eval 'Mix.Tasks.Lattice.Audit.run_release()'"

  Or via Mix in development:

      mix lattice.audit

  ## Exit Codes

  - `0` — audit completed successfully
  - `1` — audit encountered errors

  ## Options

  - `--timeout` — max milliseconds to wait for audit completion (default: 30000)
  """

  use Mix.Task

  require Logger

  alias Lattice.Events
  alias Lattice.Sprites.FleetManager

  @default_timeout 30_000

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [timeout: :integer])
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Start the application (this boots the supervision tree including
    # FleetManager, PubSub, Registry, etc.)
    Mix.Task.run("app.start")

    do_audit(timeout)
  end

  @doc """
  Entry point for release mode (no Mix available).

  Called via:

      /app/bin/lattice eval 'Mix.Tasks.Lattice.Audit.run_release()'

  In a release context the application is already started by `eval`,
  so we skip `app.start` and go straight to the audit.
  """
  @spec run_release(keyword()) :: :ok
  def run_release(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    do_audit(timeout)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp do_audit(timeout) do
    Logger.info("Lattice audit starting")

    # Subscribe to fleet events so we can observe the audit outcome
    :ok = Events.subscribe_fleet()

    # Trigger the fleet-wide audit
    :ok = FleetManager.run_audit()

    # Wait for the fleet summary broadcast that follows the audit
    result =
      receive do
        {:fleet_summary, summary} ->
          {:ok, summary}
      after
        timeout ->
          {:error, :timeout}
      end

    case result do
      {:ok, summary} ->
        Logger.info(
          "Lattice audit complete: #{summary.total} sprites, " <>
            "states: #{inspect(summary.by_state)}"
        )

        :ok

      {:error, :timeout} ->
        Logger.error("Lattice audit timed out after #{timeout}ms")
        exit({:shutdown, 1})
    end
  end
end
