defmodule Lattice.DIL.Runner do
  @moduledoc """
  Orchestrator for the Daily Improvement Loop.

  `run/1` is the single entry point called by the cron task. It checks
  whether DIL is enabled, runs all safety gates, gathers context, evaluates
  candidates, formats proposals, and returns the result. In dry-run mode
  (default) the proposal is logged but not created on GitHub.
  """

  require Logger

  alias Lattice.DIL.Context
  alias Lattice.DIL.Evaluator
  alias Lattice.DIL.Gates
  alias Lattice.DIL.Proposal

  @type result ::
          {:ok, :disabled}
          | {:ok, {:skipped, String.t()}}
          | {:ok, {:no_candidate, map()}}
          | {:ok, {:candidate, map()}}
          | {:error, term()}

  @doc """
  Run the Daily Improvement Loop.

  Options:
  - `:skip_gates` — bypass safety gates (used by ad-hoc API endpoint)

  Returns:
  - `{:ok, :disabled}` — DIL feature flag is off (only when gates not skipped)
  - `{:ok, {:skipped, reason}}` — a safety gate blocked execution
  - `{:ok, {:no_candidate, summary}}` — gates passed, no candidate above threshold
  - `{:ok, {:candidate, summary}}` — top candidate identified and formatted
  - `{:error, reason}` — unexpected failure
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    skip_gates = Keyword.get(opts, :skip_gates, false)

    with :ok <- check_gates(skip_gates) do
      run_pipeline()
    end
  rescue
    error ->
      Logger.error("DIL: unexpected error — #{inspect(error)}")
      {:error, error}
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp check_gates(true = _skip) do
    Logger.info("DIL: gates skipped (ad-hoc run)")
    :ok
  end

  defp check_gates(false) do
    if Gates.enabled?() do
      case Gates.check_all() do
        {:ok, :gates_passed} ->
          Logger.info("DIL: all gates passed")
          :ok

        {:skip, reason} ->
          Logger.info("DIL: skipped — #{reason}")
          {:ok, {:skipped, reason}}
      end
    else
      Logger.info("DIL: disabled, skipping")
      {:ok, :disabled}
    end
  end

  defp run_pipeline do
    Logger.info("DIL: gathering context")
    context = Context.gather()

    signal_counts = %{
      todos: length(context.todos),
      missing_moduledocs: length(context.missing_moduledocs),
      missing_typespecs: length(context.missing_typespecs),
      large_files: length(context.large_files),
      test_gaps: length(context.test_gaps),
      recent_issues: length(context.recent_issues)
    }

    Logger.info("DIL: context gathered — #{inspect(signal_counts)}")

    candidates = Evaluator.identify_candidates(context)
    Logger.info("DIL: #{length(candidates)} candidate(s) identified")

    case Evaluator.select_top(candidates) do
      nil ->
        Logger.info("DIL: no candidate above threshold")
        {:ok, {:no_candidate, %{signal_counts: signal_counts, candidates: length(candidates)}}}

      top ->
        handle_candidate(top, signal_counts)
    end
  end

  defp handle_candidate(candidate, signal_counts) do
    title = Proposal.format_title(candidate)
    body = Proposal.format_body(candidate)
    labels = Proposal.labels()
    mode = dil_config()[:mode] || :dry_run

    Logger.info(
      "DIL: top candidate — #{candidate.title} (score: #{candidate.total_score}/25, category: #{candidate.category}, mode: #{mode})"
    )

    if mode == :dry_run do
      Logger.info(
        "DIL [dry-run] would create issue:\n  Title: #{title}\n  Labels: #{inspect(labels)}\n\n#{body}"
      )
    end

    {:ok,
     {:candidate,
      %{
        title: title,
        category: candidate.category,
        total_score: candidate.total_score,
        scores: candidate.scores,
        evidence_count: length(candidate.evidence),
        files: candidate.files,
        labels: labels,
        mode: mode,
        signal_counts: signal_counts
      }}}
  end

  defp dil_config, do: Application.get_env(:lattice, :dil, [])
end
