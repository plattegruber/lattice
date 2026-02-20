defmodule Lattice.Capabilities.GitHub.Http do
  @moduledoc """
  HTTP-based implementation of the GitHub capability using the REST and GraphQL APIs.

  Replaces `GitHub.Live` (which shells out to the `gh` CLI) with direct HTTP
  calls via `:httpc`. This works in any environment — including Fly.io where
  `gh` is not installed.

  ## Token Resolution

  The GitHub token is resolved in order:

  1. Per-request override via process dictionary (`:lattice_github_token`)
  2. `Application.get_env(:lattice, :github_token)`
  3. `GITHUB_TOKEN` environment variable

  ## Configuration

  The target repository is read from `Lattice.Instance.resource(:github_repo)`.
  """

  @behaviour Lattice.Capabilities.GitHub

  require Logger

  alias Lattice.Events
  alias Lattice.Capabilities.GitHub.Review
  alias Lattice.Capabilities.GitHub.ReviewComment
  alias Lattice.Capabilities.GitHub.Project
  alias Lattice.Capabilities.GitHub.ProjectItem

  @api_base "https://api.github.com"
  @graphql_url "https://api.github.com/graphql"

  # ── Issues ─────────────────────────────────────────────────────────

  @impl true
  def create_issue(title, attrs) do
    body_text = Map.get(attrs, :body, "")
    labels = Map.get(attrs, :labels, [])

    payload = %{title: title, body: body_text, labels: labels}

    timed(:create_issue, fn ->
      case api_post("/repos/#{repo()}/issues", payload) do
        {:ok, data} -> {:ok, parse_issue_from_json(data)}
        error -> error
      end
    end)
  end

  @impl true
  def update_issue(number, attrs) do
    payload =
      %{}
      |> maybe_put(:title, attrs)
      |> maybe_put(:body, attrs)
      |> maybe_put(:state, attrs)

    timed(:update_issue, fn ->
      case api_patch("/repos/#{repo()}/issues/#{number}", payload) do
        {:ok, data} -> {:ok, parse_issue_from_json(data)}
        error -> error
      end
    end)
  end

  @impl true
  def add_label(number, label) do
    timed(:add_label, fn ->
      case api_post("/repos/#{repo()}/issues/#{number}/labels", %{labels: [label]}) do
        {:ok, labels} when is_list(labels) ->
          {:ok, Enum.map(labels, fn l -> l["name"] end)}

        error ->
          error
      end
    end)
  end

  @impl true
  def remove_label(number, label) do
    timed(:remove_label, fn ->
      encoded = URI.encode(label)

      case api_delete("/repos/#{repo()}/issues/#{number}/labels/#{encoded}") do
        {:ok, labels} when is_list(labels) ->
          {:ok, Enum.map(labels, fn l -> l["name"] end)}

        {:ok, _} ->
          # Fetch current labels as fallback
          case api_get("/repos/#{repo()}/issues/#{number}/labels") do
            {:ok, labels} -> {:ok, Enum.map(labels, fn l -> l["name"] end)}
            error -> error
          end

        error ->
          error
      end
    end)
  end

  @impl true
  def create_comment(number, body) do
    timed(:create_comment, fn ->
      case api_post("/repos/#{repo()}/issues/#{number}/comments", %{body: body}) do
        {:ok, data} ->
          {:ok,
           %{
             id: data["id"],
             body: data["body"],
             issue_number: number
           }}

        error ->
          error
      end
    end)
  end

  @impl true
  def list_issues(opts) do
    labels = Keyword.get(opts, :labels, [])
    state = Keyword.get(opts, :state, "open")
    limit = Keyword.get(opts, :limit, 100)

    query =
      [state: state, per_page: limit]
      |> then(fn q ->
        if labels != [], do: q ++ [labels: Enum.join(labels, ",")], else: q
      end)

    timed(:list_issues, fn ->
      case api_get("/repos/#{repo()}/issues", query) do
        {:ok, items} when is_list(items) ->
          # GitHub REST API returns PRs in issues endpoint — filter them out
          issues = Enum.reject(items, fn i -> Map.has_key?(i, "pull_request") end)
          {:ok, Enum.map(issues, &parse_issue_from_json/1)}

        error ->
          error
      end
    end)
  end

  @impl true
  def get_issue(number) do
    timed(:get_issue, fn ->
      case api_get("/repos/#{repo()}/issues/#{number}") do
        {:ok, data} when is_map(data) ->
          # Fetch comments separately since REST issues endpoint doesn't include them inline
          comments =
            case api_get("/repos/#{repo()}/issues/#{number}/comments") do
              {:ok, c} when is_list(c) -> c
              _ -> []
            end

          {:ok, parse_issue_from_json(Map.put(data, "comments_data", comments))}

        error ->
          error
      end
    end)
  end

  # ── Pull Requests ──────────────────────────────────────────────────

  @impl true
  def create_pull_request(attrs) do
    title = Map.fetch!(attrs, :title)
    head = Map.fetch!(attrs, :head)
    base = Map.fetch!(attrs, :base)
    body_text = Map.get(attrs, :body, "")
    draft = Map.get(attrs, :draft, false)

    payload = %{title: title, head: head, base: base, body: body_text, draft: draft}

    timed(:create_pull_request, fn ->
      case api_post("/repos/#{repo()}/pulls", payload) do
        {:ok, data} -> {:ok, parse_pr_from_json(data)}
        error -> error
      end
    end)
  end

  @impl true
  def get_pull_request(number) do
    timed(:get_pull_request, fn ->
      case api_get("/repos/#{repo()}/pulls/#{number}") do
        {:ok, data} when is_map(data) -> {:ok, parse_pr_from_json(data)}
        error -> error
      end
    end)
  end

  @impl true
  def update_pull_request(number, attrs) do
    payload =
      %{}
      |> maybe_put(:title, attrs)
      |> maybe_put(:body, attrs)
      |> maybe_put(:base, attrs)

    timed(:update_pull_request, fn ->
      case api_patch("/repos/#{repo()}/pulls/#{number}", payload) do
        {:ok, data} -> {:ok, parse_pr_from_json(data)}
        error -> error
      end
    end)
  end

  @impl true
  def merge_pull_request(number, opts) do
    method = Keyword.get(opts, :method, :merge)

    merge_method =
      case method do
        :squash -> "squash"
        :rebase -> "rebase"
        _ -> "merge"
      end

    timed(:merge_pull_request, fn ->
      case api_put("/repos/#{repo()}/pulls/#{number}/merge", %{merge_method: merge_method}) do
        {:ok, _} -> get_pull_request(number)
        error -> error
      end
    end)
  end

  @impl true
  def list_pull_requests(opts) do
    state = Keyword.get(opts, :state, "open")
    base = Keyword.get(opts, :base)
    head = Keyword.get(opts, :head)
    limit = Keyword.get(opts, :limit, 100)

    query =
      [state: state, per_page: limit]
      |> then(fn q -> if base, do: q ++ [base: base], else: q end)
      |> then(fn q -> if head, do: q ++ [head: head], else: q end)

    timed(:list_pull_requests, fn ->
      case api_get("/repos/#{repo()}/pulls", query) do
        {:ok, prs} when is_list(prs) ->
          {:ok, Enum.map(prs, &parse_pr_from_json/1)}

        error ->
          error
      end
    end)
  end

  # ── Branches ───────────────────────────────────────────────────────

  @impl true
  def create_branch(name, base) do
    timed(:create_branch, fn ->
      # Resolve the base ref to a SHA
      case api_get("/repos/#{repo()}/git/ref/heads/#{base}") do
        {:ok, %{"object" => %{"sha" => sha}}} ->
          case api_post("/repos/#{repo()}/git/refs", %{ref: "refs/heads/#{name}", sha: sha}) do
            {:ok, _} -> {:ok, :ok}
            error -> error
          end

        error ->
          error
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def delete_branch(name) do
    timed(:delete_branch, fn ->
      case api_delete("/repos/#{repo()}/git/refs/heads/#{name}") do
        {:ok, _} -> {:ok, :ok}
        error -> error
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  # ── Reviews ────────────────────────────────────────────────────────

  @impl true
  def list_reviews(pr_number) do
    timed(:list_reviews, fn ->
      case api_get("/repos/#{repo()}/pulls/#{pr_number}/reviews") do
        {:ok, reviews} when is_list(reviews) ->
          {:ok, Enum.map(reviews, &Review.from_json/1)}

        error ->
          error
      end
    end)
  end

  @impl true
  def list_review_comments(pr_number) do
    timed(:list_review_comments, fn ->
      case api_get("/repos/#{repo()}/pulls/#{pr_number}/comments") do
        {:ok, comments} when is_list(comments) ->
          {:ok, Enum.map(comments, &ReviewComment.from_json/1)}

        error ->
          error
      end
    end)
  end

  @impl true
  def create_review_comment(pr_number, body, path, line, opts) do
    commit_id = Keyword.get(opts, :commit_id)
    side = Keyword.get(opts, :side, "RIGHT")

    payload =
      %{body: body, path: path, line: line, side: side}
      |> then(fn p -> if commit_id, do: Map.put(p, :commit_id, commit_id), else: p end)

    timed(:create_review_comment, fn ->
      case api_post("/repos/#{repo()}/pulls/#{pr_number}/comments", payload) do
        {:ok, data} when is_map(data) -> {:ok, ReviewComment.from_json(data)}
        error -> error
      end
    end)
  end

  # ── Assignments & Reviews ──────────────────────────────────────────

  @impl true
  def assign_issue(number, usernames) when is_list(usernames) do
    timed(:assign_issue, fn ->
      case api_post("/repos/#{repo()}/issues/#{number}/assignees", %{assignees: usernames}) do
        {:ok, data} -> {:ok, parse_issue_from_json(data)}
        error -> error
      end
    end)
  end

  @impl true
  def unassign_issue(number, usernames) when is_list(usernames) do
    timed(:unassign_issue, fn ->
      case api_request(:delete, "/repos/#{repo()}/issues/#{number}/assignees",
             body: %{assignees: usernames}
           ) do
        {:ok, data} -> {:ok, parse_issue_from_json(data)}
        error -> error
      end
    end)
  end

  @impl true
  def request_review(pr_number, usernames) when is_list(usernames) do
    timed(:request_review, fn ->
      case api_post("/repos/#{repo()}/pulls/#{pr_number}/requested_reviewers", %{
             reviewers: usernames
           }) do
        {:ok, _} -> {:ok, :ok}
        error -> error
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def list_collaborators(_opts) do
    timed(:list_collaborators, fn ->
      case api_get("/repos/#{repo()}/collaborators", per_page: 100) do
        {:ok, collabs} when is_list(collabs) ->
          {:ok, Enum.map(collabs, fn c -> %{login: c["login"]} end)}

        error ->
          error
      end
    end)
  end

  # ── Projects v2 (GraphQL) ─────────────────────────────────────────

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

    timed(:list_projects, fn ->
      case graphql(query, %{owner: owner, first: 20}) do
        {:ok, %{"data" => data}} ->
          nodes =
            get_in(data, ["user", "projectsV2", "nodes"]) ||
              get_in(data, ["organization", "projectsV2", "nodes"]) || []

          {:ok, Enum.map(nodes, &Project.from_graphql/1)}

        {:ok, %{"errors" => errors}} ->
          {:error, {:graphql_errors, errors}}

        error ->
          error
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

    timed(:get_project, fn ->
      case graphql(query, %{id: project_id}) do
        {:ok, %{"data" => %{"node" => node}}} when not is_nil(node) ->
          {:ok, Project.from_graphql(node)}

        {:ok, %{"data" => %{"node" => nil}}} ->
          {:error, :not_found}

        {:ok, %{"errors" => errors}} ->
          {:error, {:graphql_errors, errors}}

        error ->
          error
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

    timed(:list_project_items, fn ->
      case graphql(query, %{id: project_id, first: 50}) do
        {:ok, %{"data" => %{"node" => %{"items" => %{"nodes" => nodes}}}}}
        when is_list(nodes) ->
          {:ok, Enum.map(nodes, &ProjectItem.from_graphql/1)}

        {:ok, %{"data" => %{"node" => nil}}} ->
          {:error, :not_found}

        {:ok, %{"errors" => errors}} ->
          {:error, {:graphql_errors, errors}}

        error ->
          error
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

    timed(:add_to_project, fn ->
      case graphql(query, %{projectId: project_id, contentId: content_id}) do
        {:ok, %{"data" => %{"addProjectV2ItemById" => %{"item" => %{"id" => item_id}}}}} ->
          {:ok, %{item_id: item_id}}

        {:ok, %{"errors" => errors}} ->
          {:error, {:graphql_errors, errors}}

        error ->
          error
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

    variables = %{
      projectId: project_id,
      itemId: item_id,
      fieldId: field_id,
      value: %{singleSelectOptionId: value}
    }

    timed(:update_project_item_field, fn ->
      case graphql(query, variables) do
        {:ok, %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => item}}}} ->
          {:ok, %{item_id: item["id"]}}

        {:ok, %{"errors" => errors}} ->
          {:error, {:graphql_errors, errors}}

        error ->
          error
      end
    end)
  end

  # ── Reactions ────────────────────────────────────────────────────

  @impl true
  def create_comment_reaction(comment_id, reaction) do
    timed(:create_comment_reaction, fn ->
      case api_post("/repos/#{repo()}/issues/comments/#{comment_id}/reactions", %{
             content: reaction
           }) do
        {:ok, data} -> {:ok, %{id: data["id"], content: data["content"]}}
        error -> error
      end
    end)
  end

  @impl true
  def create_issue_reaction(number, reaction) do
    timed(:create_issue_reaction, fn ->
      case api_post("/repos/#{repo()}/issues/#{number}/reactions", %{content: reaction}) do
        {:ok, data} -> {:ok, %{id: data["id"], content: data["content"]}}
        error -> error
      end
    end)
  end

  @impl true
  def create_review_comment_reaction(comment_id, reaction) do
    timed(:create_review_comment_reaction, fn ->
      case api_post(
             "/repos/#{repo()}/pulls/comments/#{comment_id}/reactions",
             %{content: reaction}
           ) do
        {:ok, data} -> {:ok, %{id: data["id"], content: data["content"]}}
        error -> error
      end
    end)
  end

  # ── Comments (list) ─────────────────────────────────────────────

  @impl true
  def list_comments(number) do
    timed(:list_comments, fn ->
      case api_get("/repos/#{repo()}/issues/#{number}/comments", per_page: 100) do
        {:ok, comments} when is_list(comments) ->
          {:ok,
           Enum.map(comments, fn c ->
             %{
               id: c["id"],
               body: c["body"] || "",
               user: get_in(c, ["user", "login"]) || "unknown",
               created_at: c["created_at"]
             }
           end)}

        error ->
          error
      end
    end)
  end

  # ── Private: HTTP Helpers ──────────────────────────────────────────

  defp api_get(path, query \\ []) do
    url =
      if query == [] do
        "#{@api_base}#{path}"
      else
        qs = URI.encode_query(query)
        "#{@api_base}#{path}?#{qs}"
      end

    api_request(:get, url)
  end

  defp api_post(path, body) do
    api_request(:post, "#{@api_base}#{path}", body: body)
  end

  defp api_patch(path, body) do
    api_request(:patch, "#{@api_base}#{path}", body: body)
  end

  defp api_put(path, body) do
    api_request(:put, "#{@api_base}#{path}", body: body)
  end

  defp api_delete(path) do
    api_request(:delete, "#{@api_base}#{path}")
  end

  defp api_request(method, url, opts \\ []) do
    token = resolve_token()

    if is_nil(token) or token == "" do
      {:error, :no_github_token}
    else
      headers = [
        {~c"authorization", ~c"Bearer #{token}"},
        {~c"accept", ~c"application/vnd.github+json"},
        {~c"x-github-api-version", ~c"2022-11-28"},
        {~c"user-agent", ~c"Lattice/1.0"}
      ]

      body = Keyword.get(opts, :body)

      request =
        case {method, body} do
          {:get, _} ->
            {String.to_charlist(url), headers}

          {:delete, nil} ->
            {String.to_charlist(url), headers}

          {:delete, body} ->
            json = Jason.encode!(body)

            {String.to_charlist(url), headers, ~c"application/json", json}

          {_, body} ->
            json = Jason.encode!(body)

            {String.to_charlist(url), headers, ~c"application/json", json}
        end

      http_opts = [timeout: 30_000, connect_timeout: 10_000]

      Logger.debug("GitHub HTTP #{method} #{url}")

      case :httpc.request(method, request, http_opts, []) do
        {:ok, {{_, status, _}, _resp_headers, resp_body}} when status in 200..299 ->
          body_str = to_string(resp_body)

          if body_str == "" do
            {:ok, %{}}
          else
            case Jason.decode(body_str) do
              {:ok, decoded} -> {:ok, decoded}
              {:error, _} -> {:error, {:invalid_json, body_str}}
            end
          end

        {:ok, {{_, 204, _}, _resp_headers, _resp_body}} ->
          {:ok, %{}}

        {:ok, {{_, 404, _}, _resp_headers, _resp_body}} ->
          {:error, :not_found}

        {:ok, {{_, 401, _}, _resp_headers, _resp_body}} ->
          {:error, :unauthorized}

        {:ok, {{_, 403, _}, _resp_headers, resp_body}} ->
          body_str = to_string(resp_body)

          if String.contains?(body_str, "rate limit") do
            {:error, :rate_limited}
          else
            {:error, {:forbidden, body_str}}
          end

        {:ok, {{_, 422, _}, _resp_headers, resp_body}} ->
          body_str = to_string(resp_body)

          case Jason.decode(body_str) do
            {:ok, data} -> {:error, {:validation_error, data}}
            _ -> {:error, {:unprocessable, body_str}}
          end

        {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
          {:error, {:http_error, status, to_string(resp_body)}}

        {:error, reason} ->
          Logger.error("GitHub HTTP request failed: #{inspect(reason)}")
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp graphql(query, variables) do
    token = resolve_token()

    if is_nil(token) or token == "" do
      {:error, :no_github_token}
    else
      headers = [
        {~c"authorization", ~c"Bearer #{token}"},
        {~c"accept", ~c"application/json"},
        {~c"user-agent", ~c"Lattice/1.0"}
      ]

      body = Jason.encode!(%{query: query, variables: variables})

      request =
        {String.to_charlist(@graphql_url), headers, ~c"application/json",
         String.to_charlist(body)}

      http_opts = [timeout: 30_000, connect_timeout: 10_000]

      case :httpc.request(:post, request, http_opts, []) do
        {:ok, {{_, 200, _}, _resp_headers, resp_body}} ->
          case Jason.decode(to_string(resp_body)) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, _} -> {:error, {:invalid_json, to_string(resp_body)}}
          end

        {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
          {:error, {:http_error, status, to_string(resp_body)}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  # ── Private: Token Resolution ──────────────────────────────────────

  defp resolve_token do
    Process.get(:lattice_github_token) ||
      app_token() ||
      Application.get_env(:lattice, :github_token) ||
      System.get_env("GITHUB_TOKEN")
  end

  defp app_token do
    alias Lattice.Capabilities.GitHub.AppAuth

    if AppAuth.configured?() do
      AppAuth.token()
    else
      nil
    end
  end

  # ── Private: Telemetry ─────────────────────────────────────────────

  defp timed(operation, fun) do
    start_time = System.monotonic_time(:millisecond)
    result = fun.()
    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, _} ->
        Events.emit_capability_call(:github, operation, duration_ms, :ok)

      {:error, _} = error ->
        Events.emit_capability_call(:github, operation, duration_ms, error)
        Logger.error("GitHub #{operation} failed: #{inspect(error)}")
    end

    result
  end

  # ── Private: Parsing ───────────────────────────────────────────────

  defp parse_issue_from_json(data) when is_map(data) do
    labels =
      (data["labels"] || [])
      |> Enum.map(fn
        %{"name" => name} -> name
        name when is_binary(name) -> name
      end)

    # Comments may come from separate API call (comments_data) or inline
    comments_raw = data["comments_data"] || data["comments"] || []

    comments =
      if is_list(comments_raw) do
        Enum.map(comments_raw, fn comment ->
          %{
            id: comment["id"] || comment["databaseId"],
            body: comment["body"] || ""
          }
        end)
      else
        []
      end

    %{
      number: data["number"],
      title: data["title"],
      body: data["body"] || "",
      state: normalize_issue_state(data["state"]),
      labels: labels,
      comments: comments
    }
  end

  defp normalize_issue_state("closed"), do: "closed"
  defp normalize_issue_state("CLOSED"), do: "closed"
  defp normalize_issue_state(_), do: "open"

  defp parse_pr_from_json(data) when is_map(data) do
    labels =
      (data["labels"] || [])
      |> Enum.map(fn
        %{"name" => name} -> name
        name when is_binary(name) -> name
      end)

    %{
      number: data["number"],
      title: data["title"],
      body: data["body"] || "",
      state: data["state"] || "OPEN",
      head: get_in(data, ["head", "ref"]) || data["headRefName"],
      base: get_in(data, ["base", "ref"]) || data["baseRefName"],
      mergeable: data["mergeable"],
      labels: labels,
      url: data["html_url"] || data["url"]
    }
  end

  defp maybe_put(map, key, attrs) do
    case Map.get(attrs, key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  # ── Private: Configuration ─────────────────────────────────────────

  defp repo do
    Lattice.Instance.resource(:github_repo) ||
      raise "GITHUB_REPO resource binding is not configured. " <>
              "Set the GITHUB_REPO environment variable."
  end
end
