defmodule Lattice.Capabilities.GitHub.Live do
  @moduledoc """
  Live implementation of the GitHub capability backed by the `gh` CLI.

  Uses `System.cmd("gh", ...)` to call the GitHub CLI, which handles
  authentication via its own config. This avoids managing OAuth tokens
  directly and works on any machine where `gh auth login` has been run.

  ## Configuration

  The target repository is read from `Lattice.Instance.resource(:github_repo)`.
  All operations are scoped to this repository.

  ## Telemetry

  Every GitHub API call emits a `[:lattice, :capability, :call]` telemetry
  event via `Lattice.Events.emit_capability_call/4` with:

  - capability: `:github`
  - operation: the callback name (e.g., `:create_issue`)
  - duration_ms: wall-clock time of the `gh` CLI call
  - result: `:ok` or `{:error, reason}`
  """

  @behaviour Lattice.Capabilities.GitHub

  require Logger

  alias Lattice.Events

  # ── Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def create_issue(title, attrs) do
    body = Map.get(attrs, :body, "")
    labels = Map.get(attrs, :labels, [])

    args = ["issue", "create", "--title", title, "--body", body]
    args = if labels != [], do: args ++ ["--label", Enum.join(labels, ",")], else: args

    timed_cmd(:create_issue, args, fn json ->
      parse_issue(json)
    end)
  end

  @impl true
  def update_issue(number, attrs) do
    args = ["issue", "edit", to_string(number)]

    args =
      args
      |> maybe_add_flag(attrs, :title, "--title")
      |> maybe_add_flag(attrs, :body, "--body")
      |> maybe_add_flag(attrs, :state, "--state", fn
        "closed" -> "closed"
        "open" -> "open"
        other -> other
      end)

    timed_cmd(:update_issue, args, fn _output ->
      # gh issue edit does not return JSON by default; fetch the updated issue
      get_issue(number)
    end)
  end

  @impl true
  def add_label(number, label) do
    args = ["issue", "edit", to_string(number), "--add-label", label]

    timed_cmd(:add_label, args, fn _output ->
      # Fetch the issue to get the current label list
      case get_issue_raw(number) do
        {:ok, issue} -> {:ok, Map.get(issue, "labels", []) |> extract_label_names()}
        error -> error
      end
    end)
  end

  @impl true
  def remove_label(number, label) do
    args = ["issue", "edit", to_string(number), "--remove-label", label]

    timed_cmd(:remove_label, args, fn _output ->
      # Fetch the issue to get the current label list
      case get_issue_raw(number) do
        {:ok, issue} -> {:ok, Map.get(issue, "labels", []) |> extract_label_names()}
        error -> error
      end
    end)
  end

  @impl true
  def create_comment(number, body) do
    args = ["issue", "comment", to_string(number), "--body", body]

    timed_cmd(:create_comment, args, fn _output ->
      # gh issue comment does not return the comment JSON; construct from known data
      {:ok,
       %{
         id: System.unique_integer([:positive]),
         body: body,
         issue_number: number
       }}
    end)
  end

  @impl true
  def list_issues(opts) do
    labels = Keyword.get(opts, :labels, [])
    state = Keyword.get(opts, :state, "open")
    limit = Keyword.get(opts, :limit, 100)

    args = [
      "issue",
      "list",
      "--state",
      state,
      "--limit",
      to_string(limit),
      "--json",
      "number,title,body,state,labels,comments"
    ]

    args = if labels != [], do: args ++ ["--label", Enum.join(labels, ",")], else: args

    timed_cmd(:list_issues, args, fn json ->
      case Jason.decode(json) do
        {:ok, issues} when is_list(issues) ->
          {:ok, Enum.map(issues, &parse_issue_from_json/1)}

        {:ok, _} ->
          {:ok, []}

        {:error, _} ->
          {:error, {:invalid_json, json}}
      end
    end)
  end

  @impl true
  def get_issue(number) do
    timed_cmd(:get_issue, issue_view_args(number), fn json ->
      case Jason.decode(json) do
        {:ok, data} when is_map(data) -> {:ok, parse_issue_from_json(data)}
        {:error, _} -> {:error, {:invalid_json, json}}
      end
    end)
  end

  # ── PR & Branch Callbacks ───────────────────────────────────────────────

  @pr_json_fields "number,title,body,state,headRefName,baseRefName,mergeable,labels,reviews,url"

  @impl true
  def create_pull_request(attrs) do
    title = Map.fetch!(attrs, :title)
    head = Map.fetch!(attrs, :head)
    base = Map.fetch!(attrs, :base)
    body = Map.get(attrs, :body, "")

    args = ["pr", "create", "--title", title, "--head", head, "--base", base, "--body", body]
    args = if Map.get(attrs, :draft, false), do: args ++ ["--draft"], else: args

    timed_cmd(:create_pull_request, args, fn output ->
      parse_pr_from_create_output(output)
    end)
  end

  @impl true
  def get_pull_request(number) do
    args = ["pr", "view", to_string(number), "--json", @pr_json_fields]

    timed_cmd(:get_pull_request, args, fn json ->
      case Jason.decode(json) do
        {:ok, data} when is_map(data) -> {:ok, parse_pr_from_json(data)}
        {:error, _} -> {:error, {:invalid_json, json}}
      end
    end)
  end

  @impl true
  def update_pull_request(number, attrs) do
    args =
      ["pr", "edit", to_string(number)]
      |> maybe_add_flag(attrs, :title, "--title")
      |> maybe_add_flag(attrs, :body, "--body")
      |> maybe_add_flag(attrs, :base, "--base")

    timed_cmd(:update_pull_request, args, fn _output ->
      get_pull_request(number)
    end)
  end

  @impl true
  def merge_pull_request(number, opts) do
    method = Keyword.get(opts, :method, :merge)
    delete_branch = Keyword.get(opts, :delete_branch, false)

    method_flag =
      case method do
        :squash -> "--squash"
        :rebase -> "--rebase"
        _ -> "--merge"
      end

    args = ["pr", "merge", to_string(number), method_flag, "--admin"]
    args = if delete_branch, do: args ++ ["--delete-branch"], else: args

    timed_cmd(:merge_pull_request, args, fn _output ->
      get_pull_request(number)
    end)
  end

  @impl true
  def list_pull_requests(opts) do
    state = Keyword.get(opts, :state, "open")
    base = Keyword.get(opts, :base)
    head = Keyword.get(opts, :head)
    limit = Keyword.get(opts, :limit, 100)

    args = [
      "pr",
      "list",
      "--state",
      state,
      "--limit",
      to_string(limit),
      "--json",
      @pr_json_fields
    ]

    args = if base, do: args ++ ["--base", base], else: args
    args = if head, do: args ++ ["--head", head], else: args

    timed_cmd(:list_pull_requests, args, fn json ->
      case Jason.decode(json) do
        {:ok, prs} when is_list(prs) ->
          {:ok, Enum.map(prs, &parse_pr_from_json/1)}

        {:ok, _} ->
          {:ok, []}

        {:error, _} ->
          {:error, {:invalid_json, json}}
      end
    end)
  end

  @impl true
  def create_branch(name, base) do
    # First, resolve the base ref to a SHA
    sha_args = ["api", "repos/{owner}/{repo}/git/ref/heads/#{base}", "--jq", ".object.sha"]

    timed_cmd(:create_branch, sha_args, fn sha_output ->
      sha = String.trim(sha_output)

      create_args = [
        "api",
        "repos/{owner}/{repo}/git/refs",
        "-f",
        "ref=refs/heads/#{name}",
        "-f",
        "sha=#{sha}"
      ]

      case run_gh(create_args ++ ["--repo", repo()]) do
        {:ok, _} -> {:ok, :ok}
        {:error, _} = error -> error
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def delete_branch(name) do
    args = ["api", "-X", "DELETE", "repos/{owner}/{repo}/git/refs/heads/#{name}"]

    timed_cmd(:delete_branch, args, fn _output ->
      {:ok, :ok}
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  # ── Review Callbacks ────────────────────────────────────────────────────

  alias Lattice.Capabilities.GitHub.Review
  alias Lattice.Capabilities.GitHub.ReviewComment

  @impl true
  def list_reviews(pr_number) do
    args = ["api", "repos/{owner}/{repo}/pulls/#{pr_number}/reviews"]

    timed_cmd(:list_reviews, args, fn json ->
      case Jason.decode(json) do
        {:ok, reviews} when is_list(reviews) ->
          {:ok, Enum.map(reviews, &Review.from_json/1)}

        {:ok, _} ->
          {:ok, []}

        {:error, _} ->
          {:error, {:invalid_json, json}}
      end
    end)
  end

  @impl true
  def list_review_comments(pr_number) do
    args = ["api", "repos/{owner}/{repo}/pulls/#{pr_number}/comments"]

    timed_cmd(:list_review_comments, args, fn json ->
      case Jason.decode(json) do
        {:ok, comments} when is_list(comments) ->
          {:ok, Enum.map(comments, &ReviewComment.from_json/1)}

        {:ok, _} ->
          {:ok, []}

        {:error, _} ->
          {:error, {:invalid_json, json}}
      end
    end)
  end

  @impl true
  def create_review_comment(pr_number, body, path, line, opts) do
    commit_id = Keyword.get(opts, :commit_id)
    side = Keyword.get(opts, :side, "RIGHT")

    args =
      [
        "api",
        "repos/{owner}/{repo}/pulls/#{pr_number}/comments",
        "-f",
        "body=#{body}",
        "-f",
        "path=#{path}",
        "-f",
        "line=#{line}",
        "-f",
        "side=#{side}"
      ]

    args = if commit_id, do: args ++ ["-f", "commit_id=#{commit_id}"], else: args

    timed_cmd(:create_review_comment, args, fn json ->
      case Jason.decode(json) do
        {:ok, data} when is_map(data) -> {:ok, ReviewComment.from_json(data)}
        {:error, _} -> {:error, {:invalid_json, json}}
      end
    end)
  end

  # ── Private: gh CLI Execution ──────────────────────────────────────────

  defp timed_cmd(operation, args, on_success) do
    repo = repo()
    full_args = args ++ ["--repo", repo]

    start_time = System.monotonic_time(:millisecond)

    result = run_gh(full_args)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, output} ->
        case on_success.(output) do
          {:ok, _} = success ->
            Events.emit_capability_call(:github, operation, duration_ms, :ok)
            success

          {:error, _} = error ->
            Events.emit_capability_call(:github, operation, duration_ms, error)
            error
        end

      {:error, reason} = error ->
        Events.emit_capability_call(:github, operation, duration_ms, error)
        Logger.error("GitHub #{operation} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_gh(args) do
    Logger.debug("gh #{Enum.join(args, " ")}")

    try do
      case System.cmd("gh", args, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, String.trim(output)}

        {output, exit_code} ->
          parse_gh_error(output, exit_code)
      end
    rescue
      e in ErlangError ->
        Logger.error("Failed to execute gh CLI: #{inspect(e)}")
        {:error, :gh_not_found}
    end
  end

  defp parse_gh_error(output, _exit_code) do
    cond do
      String.contains?(output, "Could not resolve to an Issue") or
          String.contains?(output, "not found") ->
        {:error, :not_found}

      String.contains?(output, "rate limit") or String.contains?(output, "API rate") ->
        {:error, :rate_limited}

      String.contains?(output, "401") or String.contains?(output, "authentication") or
          String.contains?(output, "auth login") ->
        {:error, :unauthorized}

      true ->
        {:error, {:gh_error, String.trim(output)}}
    end
  end

  # ── Private: Raw Fetchers ──────────────────────────────────────────────

  defp get_issue_raw(number) do
    repo = repo()
    args = issue_view_args(number) ++ ["--repo", repo]

    case run_gh(args) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, data} when is_map(data) -> {:ok, data}
          {:error, _} -> {:error, {:invalid_json, json}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp issue_view_args(number) do
    ["issue", "view", to_string(number), "--json", "number,title,body,state,labels,comments"]
  end

  # ── Private: Argument Building ─────────────────────────────────────────

  defp maybe_add_flag(args, attrs, key, flag) do
    maybe_add_flag(args, attrs, key, flag, &to_string/1)
  end

  defp maybe_add_flag(args, attrs, key, flag, transform) do
    case Map.get(attrs, key) do
      nil -> args
      value -> args ++ [flag, transform.(value)]
    end
  end

  # ── Private: Parsing ───────────────────────────────────────────────────

  defp parse_issue(output) do
    # gh issue create outputs a URL like: https://github.com/owner/repo/issues/42
    case Regex.run(~r|/issues/(\d+)|, output) do
      [_, number_str] ->
        number = String.to_integer(number_str)

        case get_issue_raw(number) do
          {:ok, data} -> {:ok, parse_issue_from_json(data)}
          error -> error
        end

      nil ->
        # Try to parse as JSON (in case --json flag was used)
        case Jason.decode(output) do
          {:ok, data} when is_map(data) -> {:ok, parse_issue_from_json(data)}
          _ -> {:error, {:unexpected_output, output}}
        end
    end
  end

  @doc false
  def parse_issue_from_json(data) when is_map(data) do
    %{
      number: data["number"],
      title: data["title"],
      body: data["body"] || "",
      state: data["state"] || "open",
      labels: extract_label_names(data["labels"] || []),
      comments: parse_comments(data["comments"] || [])
    }
  end

  defp extract_label_names(labels) when is_list(labels) do
    Enum.map(labels, fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
    end)
  end

  defp parse_comments(comments) when is_list(comments) do
    Enum.map(comments, fn comment ->
      %{
        id: comment["id"] || comment["databaseId"],
        body: comment["body"] || ""
      }
    end)
  end

  # ── Private: PR Parsing ───────────────────────────────────────────────

  defp parse_pr_from_create_output(output) do
    # gh pr create outputs a URL like: https://github.com/owner/repo/pull/42
    case Regex.run(~r|/pull/(\d+)|, output) do
      [_, number_str] ->
        number = String.to_integer(number_str)
        get_pull_request_raw(number)

      nil ->
        case Jason.decode(output) do
          {:ok, data} when is_map(data) -> {:ok, parse_pr_from_json(data)}
          _ -> {:error, {:unexpected_output, output}}
        end
    end
  end

  defp get_pull_request_raw(number) do
    repo = repo()
    args = ["pr", "view", to_string(number), "--json", @pr_json_fields, "--repo", repo]

    case run_gh(args) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, data} when is_map(data) -> {:ok, parse_pr_from_json(data)}
          {:error, _} -> {:error, {:invalid_json, json}}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def parse_pr_from_json(data) when is_map(data) do
    %{
      number: data["number"],
      title: data["title"],
      body: data["body"] || "",
      state: data["state"] || "OPEN",
      head: data["headRefName"],
      base: data["baseRefName"],
      mergeable: data["mergeable"],
      labels: extract_label_names(data["labels"] || []),
      url: data["url"]
    }
  end

  # ── Projects v2 Callbacks (GraphQL) ───────────────────────────────────

  alias Lattice.Capabilities.GitHub.Project
  alias Lattice.Capabilities.GitHub.ProjectItem

  @impl true
  def list_projects(_opts) do
    [owner, _repo_name] = String.split(repo(), "/")

    query = """
    query($owner: String!, $first: Int!) {
      user(login: $owner) {
        projectsV2(first: $first) {
          nodes { id title shortDescription url }
        }
      }
    }
    """

    args = [
      "api",
      "graphql",
      "-f",
      "query=#{query}",
      "-f",
      "owner=#{owner}",
      "-F",
      "first=20"
    ]

    timed_cmd(:list_projects, args, fn json ->
      case Jason.decode(json) do
        {:ok, %{"data" => data}} ->
          nodes =
            get_in(data, ["user", "projectsV2", "nodes"]) ||
              get_in(data, ["organization", "projectsV2", "nodes"]) || []

          {:ok, Enum.map(nodes, &Project.from_graphql/1)}

        {:ok, %{"errors" => errors}} ->
          {:error, {:graphql_errors, errors}}

        {:error, _} ->
          {:error, {:invalid_json, json}}
      end
    end)
  end

  @impl true
  def get_project(project_id) do
    query = """
    query($id: ID!) {
      node(id: $id) {
        ... on ProjectV2 {
          id title shortDescription url
          fields(first: 30) {
            nodes { ... on ProjectV2FieldCommon { id name dataType } }
          }
        }
      }
    }
    """

    args = ["api", "graphql", "-f", "query=#{query}", "-f", "id=#{project_id}"]

    timed_cmd(:get_project, args, fn json ->
      case Jason.decode(json) do
        {:ok, %{"data" => %{"node" => node}}} when not is_nil(node) ->
          {:ok, Project.from_graphql(node)}

        {:ok, %{"data" => %{"node" => nil}}} ->
          {:error, :not_found}

        {:ok, %{"errors" => errors}} ->
          {:error, {:graphql_errors, errors}}

        {:error, _} ->
          {:error, {:invalid_json, json}}
      end
    end)
  end

  @impl true
  def list_project_items(project_id, _opts) do
    query = """
    query($id: ID!, $first: Int!) {
      node(id: $id) {
        ... on ProjectV2 {
          items(first: $first) {
            nodes {
              id
              content { ... on Issue { id title __typename } ... on PullRequest { id title __typename } ... on DraftIssue { id title __typename } }
              fieldValues(first: 10) {
                nodes {
                  ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } }
                  ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name } } }
                  ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } }
                  ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
                  ... on ProjectV2ItemFieldIterationValue { title field { ... on ProjectV2FieldCommon { name } } }
                }
              }
            }
          }
        }
      }
    }
    """

    args = [
      "api",
      "graphql",
      "-f",
      "query=#{query}",
      "-f",
      "id=#{project_id}",
      "-F",
      "first=50"
    ]

    timed_cmd(:list_project_items, args, fn json ->
      case Jason.decode(json) do
        {:ok, %{"data" => %{"node" => %{"items" => %{"nodes" => nodes}}}}}
        when is_list(nodes) ->
          {:ok, Enum.map(nodes, &ProjectItem.from_graphql/1)}

        {:ok, %{"data" => %{"node" => nil}}} ->
          {:error, :not_found}

        {:ok, %{"errors" => errors}} ->
          {:error, {:graphql_errors, errors}}

        {:error, _} ->
          {:error, {:invalid_json, json}}
      end
    end)
  end

  @impl true
  def add_to_project(project_id, content_id) do
    query = """
    mutation($projectId: ID!, $contentId: ID!) {
      addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
        item { id }
      }
    }
    """

    args = [
      "api",
      "graphql",
      "-f",
      "query=#{query}",
      "-f",
      "projectId=#{project_id}",
      "-f",
      "contentId=#{content_id}"
    ]

    timed_cmd(:add_to_project, args, fn json ->
      case Jason.decode(json) do
        {:ok, %{"data" => %{"addProjectV2ItemById" => %{"item" => %{"id" => item_id}}}}} ->
          {:ok, %{item_id: item_id}}

        {:ok, %{"errors" => errors}} ->
          {:error, {:graphql_errors, errors}}

        {:error, _} ->
          {:error, {:invalid_json, json}}
      end
    end)
  end

  @impl true
  def update_project_item_field(project_id, item_id, field_id, value) do
    query = """
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: ProjectV2FieldValue!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: $value
      }) {
        projectV2Item { id }
      }
    }
    """

    args = [
      "api",
      "graphql",
      "-f",
      "query=#{query}",
      "-f",
      "projectId=#{project_id}",
      "-f",
      "itemId=#{item_id}",
      "-f",
      "fieldId=#{field_id}",
      "-f",
      "value={\"singleSelectOptionId\": \"#{value}\"}"
    ]

    timed_cmd(:update_project_item_field, args, fn json ->
      case Jason.decode(json) do
        {:ok, %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => item}}}} ->
          {:ok, %{item_id: item["id"]}}

        {:ok, %{"errors" => errors}} ->
          {:error, {:graphql_errors, errors}}

        {:error, _} ->
          {:error, {:invalid_json, json}}
      end
    end)
  end

  # ── Assignment & Review Request Callbacks ──────────────────────────────

  @impl true
  def assign_issue(number, usernames) when is_list(usernames) do
    assignees = Enum.join(usernames, ",")
    args = ["issue", "edit", to_string(number), "--add-assignee", assignees]

    timed_cmd(:assign_issue, args, fn _output ->
      get_issue(number)
    end)
  end

  @impl true
  def unassign_issue(number, usernames) when is_list(usernames) do
    assignees = Enum.join(usernames, ",")
    args = ["issue", "edit", to_string(number), "--remove-assignee", assignees]

    timed_cmd(:unassign_issue, args, fn _output ->
      get_issue(number)
    end)
  end

  @impl true
  def request_review(pr_number, usernames) when is_list(usernames) do
    reviewers = Enum.join(usernames, ",")
    args = ["pr", "edit", to_string(pr_number), "--add-reviewer", reviewers]

    timed_cmd(:request_review, args, fn _output ->
      {:ok, :ok}
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def list_collaborators(_opts) do
    args = ["api", "repos/{owner}/{repo}/collaborators", "--paginate", "--jq", ".[].login"]

    timed_cmd(:list_collaborators, args, fn output ->
      usernames =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:ok, Enum.map(usernames, fn login -> %{login: login} end)}
    end)
  end

  # ── Private: Configuration ─────────────────────────────────────────────

  defp repo do
    Lattice.Instance.resource(:github_repo) ||
      raise "GITHUB_REPO resource binding is not configured. " <>
              "Set the GITHUB_REPO environment variable."
  end
end
