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

    [
      "# Issue ##{number}: #{title}",
      "",
      "| Field | Value |",
      "|-------|-------|",
      "| Author | #{author} |",
      "| State | #{state} |",
      "| Labels | #{format_labels(labels)} |",
      ""
    ]
    |> append_body_section(body)
    |> append_comments_section(comments)
    |> Enum.join("\n")
    |> String.trim_trailing()
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
    pr
    |> build_pr_header_lines()
    |> append_body_section(pr[:body] || pr["body"] || "")
    |> append_diff_stats_section(Keyword.get(opts, :diff_stats))
    |> append_reviews_section(Keyword.get(opts, :reviews), Keyword.get(opts, :review_comments))
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp build_pr_header_lines(pr) do
    number = pr[:number] || pr["number"]
    title = pr[:title] || pr["title"] || ""
    author = extract_author(pr)
    labels = extract_labels(pr)
    state = pr[:state] || pr["state"] || "open"
    head = extract_branch(pr, :head, "headRefName")
    base = extract_branch(pr, :base, "baseRefName")

    [
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
  end

  defp extract_branch(pr, atom_key, alt_str_key) do
    str_key = Atom.to_string(atom_key)
    pr[atom_key] || pr[str_key] || pr[alt_str_key] || ""
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

    rows = Enum.map(files, &render_file_row/1)

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
  def render_thread([]), do: "_No comments._"

  def render_thread(comments) when is_list(comments) do
    comments
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n---\n\n", fn {comment, idx} -> format_comment(comment, idx) end)
  end

  # ── Review Rendering ────────────────────────────────────────────

  @doc """
  Render PR reviews and inline review comments as markdown.
  """
  @spec render_reviews([Review.t()], [ReviewComment.t()]) :: String.t()
  def render_reviews(reviews, review_comments \\ [])

  def render_reviews([], []), do: "_No reviews._"

  def render_reviews(reviews, review_comments) do
    review_section = Enum.map_join(reviews, "\n\n---\n\n", &format_review/1)
    inline_section = render_inline_comments(review_comments)
    review_section <> inline_section
  end

  # ── Private ──────────────────────────────────────────────────────

  defp append_body_section(lines, ""),
    do: lines ++ ["## Description", "", "_No description provided._", ""]

  defp append_body_section(lines, body),
    do: lines ++ ["## Description", "", body, ""]

  defp append_comments_section(lines, []), do: lines

  defp append_comments_section(lines, comments),
    do: lines ++ ["## Comments", "", render_thread(comments)]

  defp append_diff_stats_section(lines, nil), do: lines
  defp append_diff_stats_section(lines, []), do: lines

  defp append_diff_stats_section(lines, diff_stats),
    do: lines ++ ["## Changed Files", "", render_diff_stats(diff_stats), ""]

  defp append_reviews_section(lines, nil, _review_comments), do: lines
  defp append_reviews_section(lines, [], _review_comments), do: lines

  defp append_reviews_section(lines, reviews, review_comments),
    do: lines ++ ["## Reviews", "", render_reviews(reviews, review_comments || []), ""]

  defp render_file_row(file) do
    filename = file[:filename] || file["filename"] || ""
    status = file[:status] || file["status"] || ""
    additions = file[:additions] || file["additions"] || 0
    deletions = file[:deletions] || file["deletions"] || 0
    "| `#{filename}` | #{status} | +#{additions} | -#{deletions} |"
  end

  defp format_comment(comment, idx) do
    user = extract_comment_user(comment)
    body = comment[:body] || comment["body"] || ""
    time_str = format_timestamp(comment[:created_at] || comment["created_at"])
    "### Comment #{idx} — @#{user}#{time_str}\n\n#{body}"
  end

  defp extract_comment_user(comment) do
    comment[:user] || comment[:author] || comment["user"] || comment["author"] || "unknown"
  end

  defp format_timestamp(nil), do: ""
  defp format_timestamp(""), do: ""
  defp format_timestamp(ts), do: " (#{ts})"

  defp format_review(review) do
    state_badge = review_state_badge(review.state)
    body_str = if review.body != "", do: "\n\n#{review.body}", else: ""
    time_str = if review.submitted_at, do: " (#{review.submitted_at})", else: ""
    "### @#{review.author} — #{state_badge}#{time_str}#{body_str}"
  end

  defp render_inline_comments([]), do: ""

  defp render_inline_comments(review_comments) do
    inline_lines =
      review_comments
      |> Enum.group_by(& &1.path)
      |> Enum.sort_by(fn {path, _} -> path end)
      |> Enum.map_join("\n\n", fn {path, comments} -> format_inline_file(path, comments) end)

    "\n\n### Inline Comments\n\n#{inline_lines}"
  end

  defp format_inline_file(path, comments) do
    comment_lines =
      Enum.map_join(Enum.sort_by(comments, & &1.line), "\n", fn rc ->
        line_str = if rc.line, do: "L#{rc.line}", else: ""
        "  - **@#{rc.author}** #{line_str}: #{rc.body}"
      end)

    "- `#{path}`\n#{comment_lines}"
  end

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
