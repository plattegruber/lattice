defmodule Lattice.DIL.Evaluator do
  @moduledoc """
  Rule-based heuristic evaluator for DIL candidates.

  Maps context signals to improvement candidates in four categories
  (observability, context_efficiency, reliability, developer_ergonomics),
  scores each across five dimensions, and selects the top qualifying one.
  """

  alias Lattice.DIL.Candidate
  alias Lattice.DIL.Context

  @score_dimensions [
    :north_star_alignment,
    :evidence_strength,
    :scope_clarity,
    :risk_level,
    :implementation_confidence
  ]

  @doc """
  Identify candidate improvements from gathered context signals.
  """
  @spec identify_candidates(Context.t()) :: [Candidate.t()]
  def identify_candidates(%Context{} = ctx) do
    []
    |> maybe_add_moduledoc_candidates(ctx)
    |> maybe_add_typespec_candidates(ctx)
    |> maybe_add_todo_candidates(ctx)
    |> maybe_add_large_file_candidates(ctx)
    |> maybe_add_test_gap_candidates(ctx)
  end

  @doc """
  Score a candidate across all five dimensions. Returns the candidate
  with `scores` and `total_score` populated.
  """
  @spec score_candidate(Candidate.t()) :: Candidate.t()
  def score_candidate(%Candidate{} = candidate) do
    scores = %{
      north_star_alignment: score_north_star(candidate),
      evidence_strength: score_evidence(candidate),
      scope_clarity: score_scope(candidate),
      risk_level: score_risk(candidate),
      implementation_confidence: score_confidence(candidate)
    }

    total = scores |> Map.values() |> Enum.sum()
    %{candidate | scores: scores, total_score: total}
  end

  @doc """
  Select the top-scoring candidate above the configured threshold.
  Returns `nil` if no candidate qualifies.
  """
  @spec select_top([Candidate.t()], keyword()) :: Candidate.t() | nil
  def select_top(candidates, opts \\ []) do
    threshold = opts[:threshold] || dil_config()[:score_threshold] || 18

    candidates
    |> Enum.map(&score_candidate/1)
    |> Enum.filter(&(&1.total_score >= threshold))
    |> Enum.sort_by(& &1.total_score, :desc)
    |> List.first()
  end

  # ── Candidate Identification ─────────────────────────────────────────

  defp maybe_add_moduledoc_candidates(acc, %{missing_moduledocs: []}), do: acc

  defp maybe_add_moduledoc_candidates(acc, %{missing_moduledocs: files}) do
    file_list = Enum.map(files, & &1.file)

    candidate = %Candidate{
      id: "moduledoc-#{:erlang.phash2(file_list)}",
      title: "Add missing @moduledoc to #{length(files)} module(s)",
      category: :developer_ergonomics,
      summary:
        "#{length(files)} module(s) lack @moduledoc. Adding documentation improves discoverability and onboarding.",
      evidence: Enum.map(files, &"#{&1.file}: #{&1.detail}"),
      files: file_list,
      alternatives: ["Add @moduledoc false for intentionally undocumented modules"],
      risks: ["Minimal — documentation-only change"],
      effort: effort_for_count(length(files))
    }

    [candidate | acc]
  end

  defp maybe_add_typespec_candidates(acc, %{missing_typespecs: []}), do: acc

  defp maybe_add_typespec_candidates(acc, %{missing_typespecs: files}) do
    file_list = Enum.map(files, & &1.file)

    candidate = %Candidate{
      id: "typespecs-#{:erlang.phash2(file_list)}",
      title: "Add missing @spec to #{length(files)} module(s)",
      category: :developer_ergonomics,
      summary:
        "#{length(files)} module(s) have public functions without @spec. Type specs improve Dialyzer coverage and documentation.",
      evidence: Enum.map(files, &"#{&1.file}: #{&1.detail}"),
      files: file_list,
      alternatives: ["Run Dialyzer to identify most impactful missing specs first"],
      risks: ["Minimal — type annotation only, no behavior change"],
      effort: effort_for_count(length(files))
    }

    [candidate | acc]
  end

  defp maybe_add_todo_candidates(acc, %{todos: []}), do: acc

  defp maybe_add_todo_candidates(acc, %{todos: todos}) do
    file_list = todos |> Enum.map(& &1.file) |> Enum.uniq()

    candidate = %Candidate{
      id: "todos-#{:erlang.phash2(file_list)}",
      title: "Address #{length(todos)} TODO comment(s)",
      category: :reliability,
      summary:
        "#{length(todos)} TODO(s) found across #{length(file_list)} file(s). Resolving TODOs reduces tech debt.",
      evidence: Enum.map(todos, &"#{&1.file}:#{&1.line}: #{&1.detail}"),
      files: file_list,
      alternatives: ["Triage TODOs into GitHub issues for tracking"],
      risks: ["Varies by TODO — each needs individual assessment"],
      effort: :m
    }

    [candidate | acc]
  end

  defp maybe_add_large_file_candidates(acc, %{large_files: []}), do: acc

  defp maybe_add_large_file_candidates(acc, %{large_files: files}) do
    file_list = Enum.map(files, & &1.file)

    candidate = %Candidate{
      id: "large-files-#{:erlang.phash2(file_list)}",
      title: "Consider splitting #{length(files)} large file(s)",
      category: :context_efficiency,
      summary:
        "#{length(files)} file(s) exceed the size threshold. Large files are harder to navigate and increase context window usage.",
      evidence: Enum.map(files, &"#{&1.file}: #{&1.detail}"),
      files: file_list,
      alternatives: ["Extract helper modules", "Use module attributes to reduce boilerplate"],
      risks: ["Refactoring may affect imports and aliases across the codebase"],
      effort: :m
    }

    [candidate | acc]
  end

  defp maybe_add_test_gap_candidates(acc, %{test_gaps: []}), do: acc

  defp maybe_add_test_gap_candidates(acc, %{test_gaps: gaps}) do
    file_list = Enum.map(gaps, & &1.file)

    candidate = %Candidate{
      id: "test-gaps-#{:erlang.phash2(file_list)}",
      title: "Add tests for #{length(gaps)} untested module(s)",
      category: :reliability,
      summary:
        "#{length(gaps)} module(s) have no corresponding test file. Test coverage improves confidence in changes.",
      evidence: Enum.map(gaps, &"#{&1.file}: #{&1.detail}"),
      files: file_list,
      alternatives: ["Prioritize modules with highest change frequency"],
      risks: ["Minimal — additive test files only"],
      effort: effort_for_count(length(gaps))
    }

    [candidate | acc]
  end

  # ── Scoring Heuristics ──────────────────────────────────────────────

  defp score_north_star(%{category: :observability}), do: 5
  defp score_north_star(%{category: :reliability}), do: 4
  defp score_north_star(%{category: :developer_ergonomics}), do: 3
  defp score_north_star(%{category: :context_efficiency}), do: 4

  defp score_evidence(%{evidence: [_, _, _, _, _ | _]}), do: 5
  defp score_evidence(%{evidence: [_, _, _ | _]}), do: 4
  defp score_evidence(%{evidence: [_ | _]}), do: 3
  defp score_evidence(_), do: 1

  defp score_scope(%{effort: :xs}), do: 5
  defp score_scope(%{effort: :s}), do: 4
  defp score_scope(%{effort: :m}), do: 3

  defp score_risk(%{risks: risks}) do
    if Enum.any?(risks, &(&1 =~ ~r/[Mm]inimal/)), do: 5, else: 3
  end

  defp score_confidence(%{files: files}) when length(files) <= 3, do: 5
  defp score_confidence(%{files: files}) when length(files) <= 10, do: 4
  defp score_confidence(_), do: 3

  # ── Helpers ─────────────────────────────────────────────────────────

  defp effort_for_count(n) when n <= 3, do: :xs
  defp effort_for_count(n) when n <= 10, do: :s
  defp effort_for_count(_), do: :m

  defp dil_config, do: Application.get_env(:lattice, :dil, [])

  # Suppress unused warning for @score_dimensions — used for documentation
  # and will be referenced in future validation logic.
  def score_dimensions, do: @score_dimensions
end
