defmodule Lattice.DIL.Runner do
  @moduledoc """
  Orchestrator for the Daily Improvement Loop.

  `run/1` is the single entry point called by the cron task. It checks
  whether DIL is enabled, runs all safety gates, and returns the result.

  Future PRs will extend this to gather context, evaluate candidates,
  format proposals, and (in live mode) create GitHub issues.
  """

  require Logger

  alias Lattice.DIL.Gates

  @type result ::
          {:ok, :disabled}
          | {:ok, :gates_passed}
          | {:ok, {:skipped, String.t()}}
          | {:error, term()}

  @doc """
  Run the Daily Improvement Loop.

  Returns:
  - `{:ok, :disabled}` — DIL feature flag is off
  - `{:ok, :gates_passed}` — all gates passed (future: proposal created/logged)
  - `{:ok, {:skipped, reason}}` — a safety gate blocked execution
  - `{:error, reason}` — unexpected failure
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    _ = opts

    if not Gates.enabled?() do
      Logger.info("DIL: disabled, skipping")
      {:ok, :disabled}
    else
      case Gates.check_all() do
        {:ok, :gates_passed} ->
          Logger.info("DIL: all gates passed")
          {:ok, :gates_passed}

        {:skip, reason} ->
          Logger.info("DIL: skipped — #{reason}")
          {:ok, {:skipped, reason}}
      end
    end
  rescue
    error ->
      Logger.error("DIL: unexpected error — #{inspect(error)}")
      {:error, error}
  end
end
