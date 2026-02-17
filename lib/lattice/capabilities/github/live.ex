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

  # ── Private: Configuration ─────────────────────────────────────────────

  defp repo do
    Lattice.Instance.resource(:github_repo) ||
      raise "GITHUB_REPO resource binding is not configured. " <>
              "Set the GITHUB_REPO environment variable."
  end
end
