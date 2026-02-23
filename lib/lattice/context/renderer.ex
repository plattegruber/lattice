defmodule Lattice.Context.Renderer do
  @moduledoc """
  Pure functions that render GitHub data into markdown files.

  No side effects, no GitHub API calls. Takes structured data in,
  returns markdown strings out.
  """

  alias Lattice.Capabilities.GitHub.Review
  alias Lattice.Capabilities.GitHub.ReviewComment

  # ── Issue Rendering ──────────────────────────────────────────────

  @doc """
  Render an issue as markdown.

  Includes title, metadata block, labels, and body.
  """
  @spec render_issue(map(), [map()]) :: String.t()
  def render_issue(issue, comments \\ []) do
    number = issue[:number] || issue["number"]
    title = issue[:title] || issue["title"] || ""
    body = issue[:body] || issue["body"] || ""
    author = extract_author(issue)
    labels = extract_labels(issue)
    state = issue[:state] || issue["state"] || "open"

    lines = [
      "# Issue ##{number}: #{title}",
      "",
      "| Field | Value |",
      "|-------|-------|",
      "| Author | #{author} |",
      "| State | #{state} |",
      "| Labels | #{format_labels(labels)} |",
      ""
    ]

    lines =
      if body != "" do
        lines ++ ["## Description", "", body, ""]
      else
        lines ++ ["## Description", "", "_No description provided._", ""]
      end

    lines =
      if comments != [] do
        lines ++ ["## Comments", "", render_thread(comments)]
      else
        lines
      end

    Enum.join(lines, "\n") |> String.trim_trailing()
  end

  # ── Pull Request Rendering ──────────────────────────────────────

  @doc """
  Render a pull request as markdown.

  Includes title, metadata, branch info, body, and optionally
  diff stats and reviews.

  ## Options

    * `:diff_stats` - list of PR file maps (from `list_pr_files/1`)
    * `:reviews` - list of `%Review{}` structs
    * `:review_comments` - list of `%ReviewComment{}` structs
  """
  @spec render_pull_request(map(), keyword()) :: String.t()
  def render_pull_request(pr, opts \\ []) do
    number = pr[:number] || pr["number"]
    title = pr[:title] || pr["title"] || ""
    body = pr[:body] || pr["body"] || ""
    author = extract_author(pr)
    labels = extract_labels(pr)
    state = pr[:state] || pr["state"] || "open"
    head = pr[:head] || pr["head"] || pr["headRefName"] || ""
    base = pr[:base] || pr["base"] || pr["baseRefName"] || ""

    lines = [
      "# PR ##{number}: #{title}",
      "",
      "| Field | Value |",
      "|-------|-------|",
      "| Author | #{author} |",
      "| State | #{state} |",
      "| Labels | #{format_labels(labels)} |",
      "| Head | `#{head}` |",
      "| Base | `#{base}` |",
      ""
    ]

    lines =
      if body != "" do
        lines ++ ["## Description", "", body, ""]
      else
        lines ++ ["## Description", "", "_No description provided._", ""]
      end

    diff_stats = Keyword.get(opts, :diff_stats)

    lines =
      if diff_stats && diff_stats != [] do
        lines ++ ["## Changed Files", "", render_diff_stats(diff_stats), ""]
      else
        lines
      end

    reviews = Keyword.get(opts, :reviews)
    review_comments = Keyword.get(opts, :review_comments)

    lines =
      if reviews && reviews != [] do
        lines ++ ["## Reviews", "", render_reviews(reviews, review_comments || []), ""]
      else
        lines
      end

    Enum.join(lines, "\n") |> String.trim_trailing()
  end

  # ── Diff Stats ──────────────────────────────────────────────────

  @doc """
  Render PR file changes as a markdown table.

  Expects the list of maps from `GitHub.list_pr_files/1`, each with
  `:filename`, `:status`, `:additions`, `:deletions`.
  """
  @spec render_diff_stats([map()]) :: String.t()
  def render_diff_stats(files) when is_list(files) do
    header = [
      "| File | Status | Additions | Deletions |",
      "|------|--------|-----------|-----------|"
    ]

    rows =
      Enum.map(files, fn file ->
        filename = file[:filename] || file["filename"] || ""
        status = file[:status] || file["status"] || ""
        additions = file[:additions] || file["additions"] || 0
        deletions = file[:deletions] || file["deletions"] || 0
        "| `#{filename}` | #{status} | +#{additions} | -#{deletions} |"
      end)

    total_add =
      Enum.reduce(files, 0, fn f, acc -> acc + (f[:additions] || f["additions"] || 0) end)

    total_del =
      Enum.reduce(files, 0, fn f, acc -> acc + (f[:deletions] || f["deletions"] || 0) end)

    summary = ["", "**Total:** #{length(files)} files, +#{total_add}, -#{total_del}"]

    (header ++ rows ++ summary)
    |> Enum.join("\n")
  end

  # ── Thread Rendering ────────────────────────────────────────────

  @doc """
  Render a chronological comment thread as markdown.

  Each comment should have `:user` (or `:author`) and `:body` keys.
  """
  @spec render_thread([map()]) :: String.t()
  def render_thread(comments) when is_list(comments) do
    if comments == [] do
      "_No comments._"
    else
      comments
      |> Enum.with_index(1)
      |> Enum.map(fn {comment, idx} ->
        user =
          comment[:user] || comment[:author] || comment["user"] || comment["author"] || "unknown"

        body = comment[:body] || comment["body"] || ""
        timestamp = comment[:created_at] || comment["created_at"] || ""

        time_str = if timestamp != "", do: " (#{timestamp})", else: ""
        "### Comment #{idx} — @#{user}#{time_str}\n\n#{body}"
      end)
      |> Enum.join("\n\n---\n\n")
    end
  end

  # ── Review Rendering ────────────────────────────────────────────

  @doc """
  Render PR reviews and inline review comments as markdown.
  """
  @spec render_reviews([Review.t()], [ReviewComment.t()]) :: String.t()
  def render_reviews(reviews, review_comments \\ [])

  def render_reviews([], []), do: "_No reviews._"

  def render_reviews(reviews, review_comments) do
    review_section =
      reviews
      |> Enum.map(fn review ->
        state_badge = review_state_badge(review.state)
        body_str = if review.body != "", do: "\n\n#{review.body}", else: ""
        time_str = if review.submitted_at, do: " (#{review.submitted_at})", else: ""

        "### @#{review.author} — #{state_badge}#{time_str}#{body_str}"
      end)
      |> Enum.join("\n\n---\n\n")

    inline_section =
      if review_comments != [] do
        grouped = Enum.group_by(review_comments, & &1.path)

        inline_lines =
          grouped
          |> Enum.sort_by(fn {path, _} -> path end)
          |> Enum.map(fn {path, comments} ->
            comment_lines =
              comments
              |> Enum.sort_by(& &1.line)
              |> Enum.map(fn rc ->
                line_str = if rc.line, do: "L#{rc.line}", else: ""
                "  - **@#{rc.author}** #{line_str}: #{rc.body}"
              end)
              |> Enum.join("\n")

            "- `#{path}`\n#{comment_lines}"
          end)
          |> Enum.join("\n\n")

        "\n\n### Inline Comments\n\n#{inline_lines}"
      else
        ""
      end

    review_section <> inline_section
  end

  # ── Private ──────────────────────────────────────────────────────

  defp extract_author(data) do
    data[:author] || data["author"] ||
      get_in(data, [:user, :login]) ||
      get_in(data, ["user", "login"]) ||
      "unknown"
  end

  defp extract_labels(data) do
    labels = data[:labels] || data["labels"] || []

    Enum.map(labels, fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _ -> ""
    end)
  end

  defp format_labels([]), do: "_none_"
  defp format_labels(labels), do: Enum.map_join(labels, ", ", &"`#{&1}`")

  defp review_state_badge(:approved), do: "APPROVED"
  defp review_state_badge(:changes_requested), do: "CHANGES REQUESTED"
  defp review_state_badge(:commented), do: "COMMENTED"
  defp review_state_badge(other), do: to_string(other)
end
