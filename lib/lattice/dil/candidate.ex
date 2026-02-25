defmodule Lattice.DIL.Candidate do
  @moduledoc """
  Struct representing a DIL improvement candidate.

  Each candidate is scored across five dimensions (0-5 each) for a maximum
  total of 25. Only candidates exceeding the configured threshold (default 18)
  are eligible for proposal.
  """

  @type category :: :observability | :context_efficiency | :reliability | :developer_ergonomics

  @type scores :: %{
          north_star_alignment: non_neg_integer(),
          evidence_strength: non_neg_integer(),
          scope_clarity: non_neg_integer(),
          risk_level: non_neg_integer(),
          implementation_confidence: non_neg_integer()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          category: category(),
          summary: String.t(),
          evidence: [String.t()],
          files: [String.t()],
          scores: scores() | nil,
          total_score: non_neg_integer(),
          alternatives: [String.t()],
          risks: [String.t()],
          effort: :xs | :s | :m
        }

  @enforce_keys [:id, :title, :category, :summary]
  defstruct [
    :id,
    :title,
    :category,
    :summary,
    evidence: [],
    files: [],
    scores: nil,
    total_score: 0,
    alternatives: [],
    risks: [],
    effort: :s
  ]
end
