defmodule Lattice.DIL.EvaluatorTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.DIL.Candidate
  alias Lattice.DIL.Context
  alias Lattice.DIL.Evaluator

  describe "identify_candidates/1" do
    test "returns empty list for empty context" do
      ctx = %Context{}
      assert Evaluator.identify_candidates(ctx) == []
    end

    test "identifies moduledoc candidates" do
      ctx = %Context{
        missing_moduledocs: [
          %{file: "lib/foo.ex", line: nil, detail: "missing @moduledoc"}
        ]
      }

      candidates = Evaluator.identify_candidates(ctx)
      assert length(candidates) == 1
      assert hd(candidates).category == :developer_ergonomics
      assert hd(candidates).title =~ "moduledoc"
    end

    test "identifies typespec candidates" do
      ctx = %Context{
        missing_typespecs: [
          %{file: "lib/bar.ex", line: nil, detail: "public functions without @spec"}
        ]
      }

      candidates = Evaluator.identify_candidates(ctx)
      assert length(candidates) == 1
      assert hd(candidates).category == :developer_ergonomics
      assert hd(candidates).title =~ "@spec"
    end

    test "identifies TODO candidates" do
      ctx = %Context{
        todos: [
          %{file: "lib/baz.ex", line: 42, detail: "# TODO: fix this"}
        ]
      }

      candidates = Evaluator.identify_candidates(ctx)
      assert length(candidates) == 1
      assert hd(candidates).category == :reliability
    end

    test "identifies large file candidates" do
      ctx = %Context{
        large_files: [
          %{file: "lib/big.ex", line: nil, detail: "500 lines"}
        ]
      }

      candidates = Evaluator.identify_candidates(ctx)
      assert length(candidates) == 1
      assert hd(candidates).category == :context_efficiency
    end

    test "identifies test gap candidates" do
      ctx = %Context{
        test_gaps: [
          %{file: "lib/untested.ex", line: nil, detail: "no corresponding test file"}
        ]
      }

      candidates = Evaluator.identify_candidates(ctx)
      assert length(candidates) == 1
      assert hd(candidates).category == :reliability
    end

    test "identifies multiple candidate types from rich context" do
      ctx = %Context{
        missing_moduledocs: [%{file: "lib/a.ex", line: nil, detail: "missing @moduledoc"}],
        todos: [%{file: "lib/b.ex", line: 1, detail: "# TODO: fix"}],
        test_gaps: [%{file: "lib/c.ex", line: nil, detail: "no corresponding test file"}]
      }

      candidates = Evaluator.identify_candidates(ctx)
      assert length(candidates) == 3
    end
  end

  describe "score_candidate/1" do
    test "scores a candidate with all five dimensions" do
      candidate = %Candidate{
        id: "test-1",
        title: "Add missing @moduledoc",
        category: :developer_ergonomics,
        summary: "Test candidate",
        evidence: [
          "file.ex: missing @moduledoc",
          "other.ex: missing @moduledoc",
          "third.ex: missing @moduledoc"
        ],
        files: ["lib/file.ex", "lib/other.ex"],
        risks: ["Minimal — documentation-only change"],
        effort: :xs
      }

      scored = Evaluator.score_candidate(candidate)

      assert is_map(scored.scores)
      assert Map.has_key?(scored.scores, :north_star_alignment)
      assert Map.has_key?(scored.scores, :evidence_strength)
      assert Map.has_key?(scored.scores, :scope_clarity)
      assert Map.has_key?(scored.scores, :risk_level)
      assert Map.has_key?(scored.scores, :implementation_confidence)
      assert scored.total_score > 0
      assert scored.total_score == Enum.sum(Map.values(scored.scores))
    end

    test "higher evidence count yields higher evidence score" do
      low_evidence = %Candidate{
        id: "low",
        title: "Low",
        category: :reliability,
        summary: "s",
        evidence: ["one"],
        risks: ["Minimal"]
      }

      high_evidence = %Candidate{
        id: "high",
        title: "High",
        category: :reliability,
        summary: "s",
        evidence: ["one", "two", "three", "four", "five"],
        risks: ["Minimal"]
      }

      low_scored = Evaluator.score_candidate(low_evidence)
      high_scored = Evaluator.score_candidate(high_evidence)

      assert high_scored.scores.evidence_strength >= low_scored.scores.evidence_strength
    end
  end

  describe "select_top/2" do
    test "returns nil when no candidates" do
      assert Evaluator.select_top([]) == nil
    end

    test "returns nil when no candidate above threshold" do
      candidate = %Candidate{
        id: "weak",
        title: "Weak candidate",
        category: :developer_ergonomics,
        summary: "s",
        evidence: ["one"],
        files: Enum.map(1..20, &"lib/file#{&1}.ex"),
        risks: ["High risk of breakage"],
        effort: :m
      }

      assert Evaluator.select_top([candidate], threshold: 25) == nil
    end

    test "returns highest-scoring candidate above threshold" do
      strong = %Candidate{
        id: "strong",
        title: "Strong candidate",
        category: :observability,
        summary: "s",
        evidence: Enum.map(1..5, &"evidence #{&1}"),
        files: ["lib/one.ex"],
        risks: ["Minimal"],
        effort: :xs
      }

      weak = %Candidate{
        id: "weak",
        title: "Weak candidate",
        category: :developer_ergonomics,
        summary: "s",
        evidence: ["one"],
        files: Enum.map(1..20, &"lib/file#{&1}.ex"),
        risks: ["Significant refactoring required"],
        effort: :m
      }

      result = Evaluator.select_top([weak, strong], threshold: 15)
      assert result.id == "strong"
    end
  end
end
