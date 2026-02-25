defmodule Mix.Tasks.Lattice.Cron do
  @shortdoc "Run all periodic maintenance tasks and exit"

  @moduledoc """
  Boots the Lattice application, runs fleet audit + skill sync + credential
  sync sequentially, logs a unified summary, and exits.

  Designed for use as a Fly Scheduled Machine (hourly):

      fly machines run . --schedule hourly \\
        --env PHX_SERVER=false \\
        -- /app/bin/lattice eval "Mix.Tasks.Lattice.Cron.run_release()"

  Or via Mix in development:

      mix lattice.cron

  Each step runs independently — a failure in one does not block the others.

  ## Exit Codes

  - `0` — all steps completed successfully
  - `1` — one or more steps failed
  """

  use Mix.Task

  require Logger

  alias Lattice.Events
  alias Lattice.Sprites.CredentialSync
  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.SkillSync

  @audit_timeout 30_000

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    do_cron()
  end

  @doc """
  Entry point for release mode (no Mix available).

  Called via:

      /app/bin/lattice eval "Mix.Tasks.Lattice.Cron.run_release()"

  Release `eval` does not start the OTP application tree, so we boot it
  explicitly before running the cron steps.
  """
  @spec run_release() :: :ok
  def run_release do
    Application.ensure_all_started(:lattice)
    do_cron()
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp do_cron do
    Logger.info("Lattice cron starting")
    start = System.monotonic_time(:millisecond)

    results = [
      {:fleet_audit, run_fleet_audit()},
      {:skill_sync, run_skill_sync()},
      {:credential_sync, run_credential_sync()}
    ]

    elapsed = System.monotonic_time(:millisecond) - start
    failures = Enum.filter(results, fn {_, status} -> status != :ok end)

    Logger.info(
      "Lattice cron complete in #{elapsed}ms: " <>
        Enum.map_join(results, ", ", fn {name, status} -> "#{name}=#{inspect(status)}" end)
    )

    if failures != [] do
      Logger.error("Lattice cron: #{length(failures)} step(s) failed")
      exit({:shutdown, 1})
    end

    :ok
  end

  defp run_fleet_audit do
    Logger.info("Cron: running fleet audit")
    :ok = Events.subscribe_fleet()
    :ok = FleetManager.run_audit()

    receive do
      {:fleet_summary, summary} ->
        Logger.info(
          "Cron: fleet audit complete — #{summary.total} sprites, " <>
            "states: #{inspect(summary.by_state)}"
        )

        :ok
    after
      @audit_timeout ->
        Logger.error("Cron: fleet audit timed out after #{@audit_timeout}ms")
        {:error, :timeout}
    end
  end

  defp run_skill_sync do
    Logger.info("Cron: running skill sync")
    results = SkillSync.sync_all()
    errors = Enum.filter(results, fn {_, v} -> v != :ok end)

    if errors == [] do
      Logger.info("Cron: skill sync complete — #{map_size(results)} sprite(s)")
      :ok
    else
      Logger.warning("Cron: skill sync had #{length(errors)} failure(s)")
      {:error, :partial_failure}
    end
  end

  defp run_credential_sync do
    Logger.info("Cron: running credential sync")
    results = CredentialSync.sync_all()
    errors = Enum.filter(results, fn {_, v} -> v != :ok end)

    if errors == [] do
      Logger.info("Cron: credential sync complete — #{map_size(results)} sprite(s)")
      :ok
    else
      Logger.warning("Cron: credential sync had #{length(errors)} failure(s)")
      {:error, :partial_failure}
    end
  end
end
