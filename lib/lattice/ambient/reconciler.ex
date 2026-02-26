defmodule Lattice.Ambient.Reconciler do
  @moduledoc """
  Startup reconciler that catches missed ambient events during deploys.

  During deploys, there's a brief window where GitHub webhooks can be lost.
  This GenServer runs once on boot, scans GitHub for recent comments that
  weren't processed, and re-broadcasts them as ambient events through the
  normal PubSub channel.

  ## How It Works

  1. Waits a short delay after boot (to let other services start)
  2. Fetches recently-updated open issues via `GitHub.list_issues(since: ...)`
  3. For each issue, fetches comments and checks if the last human comment
     has a Lattice reply (indicated by `<!-- lattice:` markers)
  4. If no reply exists, broadcasts the comment as an ambient event

  ## Idempotency

  If the event was already processed (bot replied), `find_missed_comments/2`
  won't flag it. If there's a race (webhook arrives AND reconciler fires),
  the ambient responder's classification will see the existing bot reply in
  the thread context and classify as `:ignore`.

  ## Configuration

      config :lattice, Lattice.Ambient.Reconciler,
        lookback_ms: :timer.minutes(10),
        startup_delay_ms: :timer.seconds(10)
  """

  use GenServer

  require Logger

  alias Lattice.Capabilities.GitHub
  alias Lattice.Events

  @default_lookback_ms :timer.minutes(10)
  @default_startup_delay_ms :timer.seconds(10)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :reconcile, startup_delay_ms())
    {:ok, %{reconciled: false}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    {:noreply, %{state | reconciled: true}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private: Core Reconciliation ─────────────────────────────────

  defp reconcile do
    since =
      DateTime.add(DateTime.utc_now(), -lookback_ms(), :millisecond) |> DateTime.to_iso8601()

    bot_login = responder_bot_login()

    Logger.info("Ambient.Reconciler: scanning for missed events since #{since}")

    case GitHub.list_issues(state: "open", since: since, limit: 30) do
      {:ok, issues} ->
        missed = find_missed_comments(issues, bot_login)
        Logger.info("Ambient.Reconciler: found #{length(missed)} missed event(s)")
        Enum.each(missed, &broadcast_missed_event/1)

      {:error, reason} ->
        Logger.warning("Ambient.Reconciler: failed to fetch issues: #{inspect(reason)}")
    end
  end

  # ── Private: Missed Comment Detection ────────────────────────────

  @doc false
  def find_missed_comments(issues, bot_login) do
    Enum.flat_map(issues, fn issue ->
      case GitHub.list_comments(issue.number) do
        {:ok, comments} ->
          check_issue_for_missed(issue, comments, bot_login)

        {:error, _} ->
          []
      end
    end)
  end

  defp check_issue_for_missed(issue, comments, bot_login) do
    # Walk comments in reverse to find the last human comment
    comments
    |> Enum.reverse()
    |> find_last_human_comment(bot_login)
    |> case do
      nil ->
        []

      comment ->
        # Check if there's any lattice reply after this comment
        if has_lattice_reply_after?(comments, comment) do
          []
        else
          [%{issue: issue, comment: comment}]
        end
    end
  end

  defp find_last_human_comment(reversed_comments, bot_login) do
    Enum.find(reversed_comments, fn comment ->
      user = comment[:user] || ""
      body = comment[:body] || ""

      not bot_comment?(user, bot_login) and not lattice_comment?(body)
    end)
  end

  defp bot_comment?(user, bot_login) do
    String.ends_with?(user, "[bot]") or
      user == "github-actions" or
      (not is_nil(bot_login) and user == bot_login)
  end

  defp lattice_comment?(body) when is_binary(body) do
    String.contains?(body, "<!-- lattice:")
  end

  defp lattice_comment?(_), do: false

  defp has_lattice_reply_after?(comments, target_comment) do
    target_id = target_comment[:id]

    # Find the index of our target comment
    target_idx =
      Enum.find_index(comments, fn c -> c[:id] == target_id end)

    # Check if any comment after the target is a lattice comment
    comments
    |> Enum.drop((target_idx || 0) + 1)
    |> Enum.any?(fn c -> lattice_comment?(c[:body] || "") end)
  end

  # ── Private: Event Broadcasting ──────────────────────────────────

  defp broadcast_missed_event(%{issue: issue, comment: comment}) do
    repo = configured_repo()

    event = %{
      type: :issue_comment,
      surface: :issue,
      number: issue.number,
      body: comment[:body] || "",
      title: issue.title,
      context_body: issue.body,
      context_author: nil,
      author: comment[:user] || "unknown",
      comment_id: comment[:id],
      repo: repo,
      is_pull_request: false
    }

    Logger.info(
      "Ambient.Reconciler: broadcasting missed comment #{comment[:id]} on issue ##{issue.number}"
    )

    Events.broadcast_ambient_event(event)
  end

  # ── Private: Configuration ───────────────────────────────────────

  defp lookback_ms do
    config(:lookback_ms, @default_lookback_ms)
  end

  defp startup_delay_ms do
    config(:startup_delay_ms, @default_startup_delay_ms)
  end

  defp responder_bot_login do
    Application.get_env(:lattice, Lattice.Ambient.Responder, [])
    |> Keyword.get(:bot_login)
  end

  defp configured_repo do
    Lattice.Instance.resource(:github_repo) || "unknown"
  end

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
