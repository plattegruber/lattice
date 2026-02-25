defmodule Lattice.DIL.Proposal do
  @moduledoc """
  Formats a scored `%Candidate{}` into a GitHub issue body matching
  the DIL spec template: 8 sections, `dil-proposal` label, research-backed tag.
  """

  alias Lattice.DIL.Candidate

  @doc """
  Format the issue title from a candidate.

  Returns a string like `"[DIL] Improve <subsystem> via <change>"`.
  """
  @spec format_title(Candidate.t()) :: String.t()
  def format_title(%Candidate{title: title}) do
    "[DIL] #{title}"
  end

  @doc """
  Format the full issue body with all 8 DIL spec sections.
  """
  @spec format_body(Candidate.t()) :: String.t()
  def format_body(%Candidate{} = candidate) do
    [
      summary_section(candidate),
      why_section(candidate),
      evidence_section(candidate),
      proposed_change_section(candidate),
      alternatives_section(candidate),
      risks_section(candidate),
      effort_section(candidate),
      confidence_section(candidate)
    ]
    |> Enum.join("\n\n---\n\n")
  end

  @doc """
  Returns the standard DIL proposal labels.
  """
  @spec labels() :: [String.t()]
  def labels, do: ["dil-proposal", "research-backed"]

  # ── Section Builders ─────────────────────────────────────────────────

  defp summary_section(%{summary: summary}) do
    """
    #### 1. Summary

    #{summary}\
    """
  end

  defp why_section(%{category: category}) do
    mapping = %{
      observability:
        "Improves fleet visibility and operational awareness — core to Lattice's NOC-glass mission.",
      context_efficiency:
        "Reduces context window waste and prompt overhead — directly impacts sprite effectiveness.",
      reliability:
        "Strengthens system reliability and reduces failure modes — essential for autonomous operation.",
      developer_ergonomics:
        "Improves developer experience and codebase navigability — accelerates contribution velocity."
    }

    """
    #### 2. Why This Matters

    #{Map.get(mapping, category, "Aligns with Lattice's core mission.")}\
    """
  end

  defp evidence_section(%{evidence: evidence}) do
    items = Enum.map_join(evidence, "\n", &"- `#{&1}`")

    """
    #### 3. Evidence

    #{items}\
    """
  end

  defp proposed_change_section(%{files: files, summary: summary}) do
    file_list = Enum.map_join(files, "\n", &"- `#{&1}`")

    """
    #### 4. Proposed Change

    #{summary}

    **Files to modify:**
    #{file_list}\
    """
  end

  defp alternatives_section(%{alternatives: alternatives}) do
    items = Enum.map_join(alternatives, "\n", &"- #{&1}")

    """
    #### 5. Alternatives Considered

    #{items}\
    """
  end

  defp risks_section(%{risks: risks}) do
    items = Enum.map_join(risks, "\n", &"- #{&1}")

    """
    #### 6. Risks

    #{items}\
    """
  end

  defp effort_section(%{effort: effort}) do
    label =
      case effort do
        :xs -> "XS (1 hr or less)"
        :s -> "S (1 day or less)"
        :m -> "M (3 days or less)"
      end

    """
    #### 7. Effort Estimate

    #{label}\
    """
  end

  defp confidence_section(%{total_score: total, scores: scores}) do
    score_details =
      if scores do
        [
          "north_star_alignment: #{scores.north_star_alignment}/5",
          "evidence_strength: #{scores.evidence_strength}/5",
          "scope_clarity: #{scores.scope_clarity}/5",
          "risk_level: #{scores.risk_level}/5",
          "implementation_confidence: #{scores.implementation_confidence}/5"
        ]
        |> Enum.map_join("\n", &"  - #{&1}")
      else
        ""
      end

    """
    #### 8. Confidence Level

    > Confidence: High (#{total}/25)

    Score breakdown:
    #{score_details}\
    """
  end
end
