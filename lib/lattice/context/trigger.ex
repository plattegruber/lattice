defmodule Lattice.Context.Trigger do
  @moduledoc """
  Input struct describing what triggered context gathering.

  A trigger captures the GitHub issue or PR that initiated the work,
  along with enough metadata to drive gathering without re-fetching.
  """

  @type t :: %__MODULE__{
          type: :issue | :pull_request,
          number: pos_integer(),
          repo: String.t(),
          raw_event: map() | nil,
          title: String.t(),
          body: String.t(),
          author: String.t(),
          labels: [String.t()],
          head_branch: String.t() | nil,
          base_branch: String.t() | nil,
          thread_context: [map()] | nil
        }

  @enforce_keys [:type, :number, :repo]
  defstruct [
    :type,
    :number,
    :repo,
    :raw_event,
    :head_branch,
    :base_branch,
    :thread_context,
    title: "",
    body: "",
    author: "unknown",
    labels: []
  ]

  @doc """
  Build a Trigger from a GitHub API issue map.

  Expects the map shape returned by `GitHub.get_issue/1`.
  """
  @spec from_issue(map(), String.t()) :: t()
  def from_issue(issue, repo) when is_map(issue) and is_binary(repo) do
    %__MODULE__{
      type: :issue,
      number: issue[:number] || issue["number"],
      repo: repo,
      title: issue[:title] || issue["title"] || "",
      body: issue[:body] || issue["body"] || "",
      author: extract_author(issue),
      labels: extract_labels(issue),
      raw_event: issue
    }
  end

  @doc """
  Build a Trigger from a GitHub API pull request map.

  Expects the map shape returned by `GitHub.get_pull_request/1`.
  """
  @spec from_pull_request(map(), String.t()) :: t()
  def from_pull_request(pr, repo) when is_map(pr) and is_binary(repo) do
    %__MODULE__{
      type: :pull_request,
      number: pr[:number] || pr["number"],
      repo: repo,
      title: extract_text_field(pr, "title"),
      body: extract_text_field(pr, "body"),
      author: extract_author(pr),
      labels: extract_labels(pr),
      head_branch: pr[:head] || pr["head"] || pr["headRefName"],
      base_branch: pr[:base] || pr["base"] || pr["baseRefName"],
      raw_event: pr
    }
  end

  @doc """
  Build a Trigger from an ambient responder event map.

  Infers type from the event's `:surface` field.
  """
  @spec from_ambient_event(map()) :: t()
  def from_ambient_event(event) when is_map(event) do
    type =
      case event[:surface] do
        :pr_review -> :pull_request
        :pr_review_comment -> :pull_request
        _ -> :issue
      end

    %__MODULE__{
      type: type,
      number: event[:number],
      repo: event[:repo] || Lattice.Instance.resource(:github_repo),
      title: event[:title] || "",
      body: event[:context_body] || "",
      author: event[:author] || "unknown",
      labels: event[:labels] || [],
      raw_event: event
    }
  end

  # ── Private ──────────────────────────────────────────────────────

  defp extract_text_field(data, str_key) do
    atom_key = String.to_existing_atom(str_key)
    data[atom_key] || data[str_key] || ""
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
end
