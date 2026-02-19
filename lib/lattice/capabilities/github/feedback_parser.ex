defmodule Lattice.Capabilities.GitHub.FeedbackParser do
  @moduledoc """
  Pure function module that transforms GitHub PR review data into
  structured feedback signals.

  Takes lists of `%Review{}` and `%ReviewComment{}` structs from the
  GitHub capability and produces actionable signals for intent creation.
  """

  alias Lattice.Capabilities.GitHub.Review
  alias Lattice.Capabilities.GitHub.ReviewComment

  @type feedback_signal ::
          {:approved, String.t()}
          | {:changes_requested, String.t(), [ReviewComment.t()]}
          | {:commented, String.t(), [ReviewComment.t()]}

  @action_keywords ~w(please should fix change add remove update rename move delete replace refactor)

  @doc """
  Parse reviews into structured feedback signals.

  Groups inline comments by reviewer and returns one signal per review:
  - `{:approved, reviewer}` — reviewer approved
  - `{:changes_requested, reviewer, comments}` — reviewer wants changes
  - `{:commented, reviewer, comments}` — general feedback
  """
  @spec parse_reviews([Review.t()], [ReviewComment.t()]) :: [feedback_signal()]
  def parse_reviews(reviews, comments \\ []) do
    comments_by_author = group_by_author(comments)

    reviews
    |> Enum.map(fn review ->
      author_comments = Map.get(comments_by_author, review.author, [])

      case review.state do
        :approved ->
          {:approved, review.author}

        :changes_requested ->
          {:changes_requested, review.author, author_comments}

        :commented ->
          {:commented, review.author, author_comments}
      end
    end)
  end

  @doc """
  Group inline review comments by file path.

  Returns a map of `%{path => [%ReviewComment{}]}`, useful for generating
  per-file fixup tasks.
  """
  @spec group_by_file([ReviewComment.t()]) :: %{String.t() => [ReviewComment.t()]}
  def group_by_file(comments) do
    comments
    |> Enum.filter(& &1.path)
    |> Enum.group_by(& &1.path)
  end

  @doc """
  Extract action items from review comments.

  Uses simple keyword matching to identify comments that likely contain
  actionable feedback. Returns only comments whose body contains one
  or more action keywords.
  """
  @spec extract_action_items([ReviewComment.t()]) :: [ReviewComment.t()]
  def extract_action_items(comments) do
    Enum.filter(comments, fn comment ->
      body_lower = String.downcase(comment.body)
      Enum.any?(@action_keywords, &String.contains?(body_lower, &1))
    end)
  end

  defp group_by_author(comments) do
    Enum.group_by(comments, & &1.author)
  end
end
