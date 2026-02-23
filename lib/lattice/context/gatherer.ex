defmodule Lattice.Context.Gatherer do
  @moduledoc """
  Assembles a context Bundle by fetching GitHub data and rendering markdown.

  Stateless module — calls the GitHub capability, uses Renderer for markdown,
  and produces a `%Bundle{}`.
  """

  require Logger

  alias Lattice.Capabilities.GitHub
  alias Lattice.Context.Bundle
  alias Lattice.Context.Renderer
  alias Lattice.Context.Trigger

  @default_max_expansions 5

  @doc """
  Gather context for the given trigger.

  ## Options

    * `:max_expansions` - maximum `#NNN` references to expand (default: 5)
  """
  @spec gather(Trigger.t(), keyword()) :: {:ok, Bundle.t()} | {:error, term()}
  def gather(%Trigger{} = trigger, opts \\ []) do
    max_expansions = Keyword.get(opts, :max_expansions, @default_max_expansions)
    bundle = Bundle.new(trigger, max_expansions: max_expansions)

    case trigger.type do
      :issue -> gather_issue(trigger, bundle)
      :pull_request -> gather_pull_request(trigger, bundle)
    end
  end

  # ── Issue Gathering ──────────────────────────────────────────────

  defp gather_issue(trigger, bundle) do
    with {:ok, issue} <- GitHub.get_issue(trigger.number),
         {:ok, comments} <- fetch_comments(trigger) do
      bundle =
        bundle
        |> add_trigger_file(Renderer.render_issue(issue, comments))
        |> add_thread_file(comments)
        |> expand_references(trigger.body, comments)

      {:ok, bundle}
    end
  end

  # ── Pull Request Gathering ──────────────────────────────────────

  defp gather_pull_request(trigger, bundle) do
    with {:ok, pr} <- GitHub.get_pull_request(trigger.number),
         {:ok, comments} <- fetch_comments(trigger),
         {:ok, pr_files} <- fetch_pr_files(trigger.number),
         {:ok, reviews} <- fetch_reviews(trigger.number),
         {:ok, review_comments} <- fetch_review_comments(trigger.number) do
      trigger_md =
        Renderer.render_pull_request(pr,
          diff_stats: pr_files,
          reviews: reviews,
          review_comments: review_comments
        )

      bundle =
        bundle
        |> add_trigger_file(trigger_md)
        |> add_thread_file(comments)
        |> add_diff_stats_file(pr_files)
        |> add_reviews_file(reviews, review_comments)
        |> expand_references(trigger.body, comments)

      {:ok, bundle}
    end
  end

  # ── File Addition ───────────────────────────────────────────────

  defp add_trigger_file(bundle, content) do
    Bundle.add_file(bundle, "trigger.md", content, "trigger")
  end

  defp add_thread_file(bundle, comments) do
    content = Renderer.render_thread(comments)
    Bundle.add_file(bundle, "thread.md", content, "thread")
  end

  defp add_diff_stats_file(bundle, []), do: bundle

  defp add_diff_stats_file(bundle, files) do
    content = Renderer.render_diff_stats(files)
    Bundle.add_file(bundle, "diff_stats.md", content, "diff_stats")
  end

  defp add_reviews_file(bundle, [], []), do: bundle

  defp add_reviews_file(bundle, reviews, review_comments) do
    content = Renderer.render_reviews(reviews, review_comments)
    Bundle.add_file(bundle, "reviews.md", content, "reviews")
  end

  # ── Reference Expansion ─────────────────────────────────────────

  defp expand_references(bundle, body, comments) do
    text = collect_text(body, comments)
    refs = extract_issue_refs(text)

    Enum.reduce(refs, bundle, fn ref_number, acc ->
      if Bundle.budget_remaining?(acc) do
        expand_single_ref(acc, ref_number)
      else
        acc
      end
    end)
  end

  defp collect_text(body, comments) do
    comment_text = Enum.map_join(comments, "\n", fn c -> c[:body] || c["body"] || "" end)

    (body || "") <> "\n" <> comment_text
  end

  @doc false
  @spec extract_issue_refs(String.t()) :: [pos_integer()]
  def extract_issue_refs(text) do
    # Remove code blocks first to avoid matching refs inside code
    cleaned = Regex.replace(~r/```[\s\S]*?```/, text, "")
    cleaned = Regex.replace(~r/`[^`]+`/, cleaned, "")

    ~r/(?<!\w)#(\d+)/
    |> Regex.scan(cleaned)
    |> Enum.map(fn [_, num] -> String.to_integer(num) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp expand_single_ref(bundle, ref_number) do
    case GitHub.get_issue(ref_number) do
      {:ok, issue} ->
        title = issue[:title] || issue["title"] || ""
        content = Renderer.render_issue(issue)
        path = "linked/issue_#{ref_number}.md"
        type = if issue[:pull_request], do: "linked_pr", else: "linked_issue"

        bundle
        |> Bundle.add_file(path, content, type)
        |> Bundle.add_linked_item("issue", ref_number, title)

      {:error, reason} ->
        Logger.warning("Context: failed to expand ##{ref_number}: #{inspect(reason)}")
        Bundle.add_warning(bundle, "Failed to expand ##{ref_number}: #{inspect(reason)}")
    end
  end

  # ── Data Fetching ───────────────────────────────────────────────

  defp fetch_comments(%Trigger{thread_context: ctx}) when is_list(ctx) do
    {:ok, ctx}
  end

  defp fetch_comments(%Trigger{number: number}) do
    GitHub.list_comments(number)
  end

  defp fetch_pr_files(pr_number) do
    case GitHub.list_pr_files(pr_number) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("Context: failed to fetch PR files: #{inspect(reason)}")
        {:ok, []}
    end
  end

  defp fetch_reviews(pr_number) do
    case GitHub.list_reviews(pr_number) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("Context: failed to fetch reviews: #{inspect(reason)}")
        {:ok, []}
    end
  end

  defp fetch_review_comments(pr_number) do
    case GitHub.list_review_comments(pr_number) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("Context: failed to fetch review comments: #{inspect(reason)}")
        {:ok, []}
    end
  end
end
