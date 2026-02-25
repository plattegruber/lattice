defmodule Lattice.DIL.ProposalTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.DIL.Candidate
  alias Lattice.DIL.Proposal

  @candidate %Candidate{
    id: "test-1",
    title: "Add missing @moduledoc to 3 module(s)",
    category: :developer_ergonomics,
    summary: "3 modules lack @moduledoc. Adding documentation improves discoverability.",
    evidence: [
      "lib/foo.ex: missing @moduledoc",
      "lib/bar.ex: missing @moduledoc",
      "lib/baz.ex: missing @moduledoc"
    ],
    files: ["lib/foo.ex", "lib/bar.ex", "lib/baz.ex"],
    scores: %{
      north_star_alignment: 3,
      evidence_strength: 4,
      scope_clarity: 5,
      risk_level: 5,
      implementation_confidence: 5
    },
    total_score: 22,
    alternatives: ["Add @moduledoc false for intentionally undocumented modules"],
    risks: ["Minimal — documentation-only change"],
    effort: :xs
  }

  describe "format_title/1" do
    test "prefixes with [DIL]" do
      title = Proposal.format_title(@candidate)
      assert title == "[DIL] Add missing @moduledoc to 3 module(s)"
    end
  end

  describe "format_body/1" do
    setup do
      %{body: Proposal.format_body(@candidate)}
    end

    test "contains all 8 sections", %{body: body} do
      assert body =~ "#### 1. Summary"
      assert body =~ "#### 2. Why This Matters"
      assert body =~ "#### 3. Evidence"
      assert body =~ "#### 4. Proposed Change"
      assert body =~ "#### 5. Alternatives Considered"
      assert body =~ "#### 6. Risks"
      assert body =~ "#### 7. Effort Estimate"
      assert body =~ "#### 8. Confidence Level"
    end

    test "includes summary text", %{body: body} do
      assert body =~ "3 modules lack @moduledoc"
    end

    test "includes evidence items", %{body: body} do
      assert body =~ "lib/foo.ex: missing @moduledoc"
      assert body =~ "lib/bar.ex: missing @moduledoc"
      assert body =~ "lib/baz.ex: missing @moduledoc"
    end

    test "includes files to modify", %{body: body} do
      assert body =~ "`lib/foo.ex`"
      assert body =~ "`lib/bar.ex`"
      assert body =~ "`lib/baz.ex`"
    end

    test "includes alternatives", %{body: body} do
      assert body =~ "@moduledoc false"
    end

    test "includes risks", %{body: body} do
      assert body =~ "Minimal"
    end

    test "includes effort estimate", %{body: body} do
      assert body =~ "XS (1 hr or less)"
    end

    test "includes confidence score", %{body: body} do
      assert body =~ "22/25"
    end

    test "includes score breakdown", %{body: body} do
      assert body =~ "north_star_alignment: 3/5"
      assert body =~ "evidence_strength: 4/5"
      assert body =~ "scope_clarity: 5/5"
    end
  end

  describe "labels/0" do
    test "returns dil-proposal and research-backed" do
      assert Proposal.labels() == ["dil-proposal", "research-backed"]
    end
  end
end
