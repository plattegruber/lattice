defmodule Lattice.Ambient.Responder do
  @moduledoc """
  GenServer that processes ambient GitHub events and decides how to respond.

  Subscribes to the `"ambient:github"` PubSub topic and processes each event:

  1. **Immediate acknowledgment** — reacts with 👀 to signal "I've seen this"
  2. **AI classification** — calls Claude to decide: respond, react, or ignore
  3. **Action** — posts a comment, adds a 👍 reaction, or does nothing

  ## Self-Loop Prevention

  Events from Lattice's own GitHub user are filtered out at the webhook layer
  (see `Webhooks.GitHub.maybe_broadcast_ambient/2`). Additionally, this module
  checks against a configurable bot username to prevent responding to itself.

  ## Cooldown

  To avoid flooding conversations, a per-thread cooldown prevents responding
  to the same issue/PR more than once within a configurable window.

  ## Configuration

      config :lattice, Lattice.Ambient.Responder,
        enabled: true,
        bot_login: "lattice-bot",
        cooldown_ms: 60_000,
        eyes_reaction: true
  """

  use GenServer

  require Logger

  alias Lattice.Ambient.Claude
  alias Lattice.Capabilities.GitHub
  alias Lattice.Events

  defmodule State do
    @moduledoc false
    defstruct cooldowns: %{},
              bot_login: nil,
              cooldown_ms: 60_000,
              eyes_reaction: true
  end

  # ── Public API ──────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    Events.subscribe_ambient()

    state = %State{
      bot_login: config(:bot_login, nil),
      cooldown_ms: config(:cooldown_ms, 60_000),
      eyes_reaction: config(:eyes_reaction, true)
    }

    Logger.info("Ambient Responder started")
    {:ok, state}
  end

  @impl true
  def handle_info({:ambient_event, event}, state) do
    # Skip events from our own bot user
    if is_self?(event, state) do
      {:noreply, state}
    else
      state = process_event(event, state)
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private: Event Processing ───────────────────────────────────

  defp process_event(event, state) do
    thread_key = thread_key(event)

    if on_cooldown?(thread_key, state) do
      Logger.debug("Ambient: skipping #{thread_key}, on cooldown")
      state
    else
      # Step 1: React with 👀 immediately
      if state.eyes_reaction do
        add_eyes_reaction(event)
      end

      # Step 2: Fetch thread context
      thread_context = fetch_thread_context(event)

      # Step 3: Classify with Claude
      case Claude.classify(event, thread_context) do
        {:ok, :respond, response_text} ->
          post_response(event, response_text)
          record_cooldown(thread_key, state)

        {:ok, :react, _} ->
          add_thumbsup_reaction(event)
          record_cooldown(thread_key, state)

        {:ok, :ignore, _} ->
          Logger.debug("Ambient: ignoring event on #{thread_key}")
          state

        {:error, reason} ->
          Logger.warning("Ambient: Claude classification failed: #{inspect(reason)}")
          state
      end
    end
  end

  # ── Private: Reactions ──────────────────────────────────────────

  defp add_eyes_reaction(event) do
    case reaction_target(event) do
      {:comment, comment_id} ->
        GitHub.create_comment_reaction(comment_id, "eyes")

      {:issue, number} ->
        GitHub.create_issue_reaction(number, "eyes")

      {:review_comment, comment_id} ->
        GitHub.create_review_comment_reaction(comment_id, "eyes")

      :none ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Ambient: failed to add 👀 reaction: #{inspect(e)}")
  end

  defp add_thumbsup_reaction(event) do
    case reaction_target(event) do
      {:comment, comment_id} ->
        GitHub.create_comment_reaction(comment_id, "+1")

      {:issue, number} ->
        GitHub.create_issue_reaction(number, "+1")

      {:review_comment, comment_id} ->
        GitHub.create_review_comment_reaction(comment_id, "+1")

      :none ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Ambient: failed to add 👍 reaction: #{inspect(e)}")
  end

  defp reaction_target(%{type: :issue_comment, comment_id: id}) when not is_nil(id),
    do: {:comment, id}

  defp reaction_target(%{type: :issue_opened, number: n}) when not is_nil(n),
    do: {:issue, n}

  defp reaction_target(%{type: :pr_review, comment_id: id}) when not is_nil(id),
    do: {:comment, id}

  defp reaction_target(%{type: :pr_review_comment, comment_id: id}) when not is_nil(id),
    do: {:review_comment, id}

  defp reaction_target(_), do: :none

  # ── Private: Response Posting ───────────────────────────────────

  defp post_response(%{surface: :issue, number: number}, text) when not is_nil(number) do
    body = "#{text}\n\n<!-- lattice:ambient -->"

    case GitHub.create_comment(number, body) do
      {:ok, _} ->
        Logger.info("Ambient: posted comment on issue ##{number}")

      {:error, reason} ->
        Logger.warning("Ambient: failed to post comment on ##{number}: #{inspect(reason)}")
    end
  end

  defp post_response(%{surface: :pr_review, number: number}, text) when not is_nil(number) do
    body = "#{text}\n\n<!-- lattice:ambient -->"

    case GitHub.create_comment(number, body) do
      {:ok, _} ->
        Logger.info("Ambient: posted comment on PR ##{number}")

      {:error, reason} ->
        Logger.warning("Ambient: failed to post comment on PR ##{number}: #{inspect(reason)}")
    end
  end

  defp post_response(%{surface: :pr_review_comment, number: number}, text)
       when not is_nil(number) do
    body = "#{text}\n\n<!-- lattice:ambient -->"

    case GitHub.create_comment(number, body) do
      {:ok, _} ->
        Logger.info("Ambient: posted comment on PR ##{number}")

      {:error, reason} ->
        Logger.warning("Ambient: failed to post comment on PR ##{number}: #{inspect(reason)}")
    end
  end

  defp post_response(event, _text) do
    Logger.warning("Ambient: don't know how to respond to surface #{inspect(event[:surface])}")
  end

  # ── Private: Thread Context ─────────────────────────────────────

  defp fetch_thread_context(%{surface: surface, number: number})
       when surface in [:issue, :pr_review, :pr_review_comment] and not is_nil(number) do
    case GitHub.list_comments(number) do
      {:ok, comments} ->
        # Take last 10 comments for context window management
        comments
        |> Enum.take(-10)
        |> Enum.map(fn c ->
          %{user: c[:user] || c.user, body: c[:body] || c.body}
        end)

      {:error, _} ->
        []
    end
  end

  defp fetch_thread_context(_), do: []

  # ── Private: Self-Detection ─────────────────────────────────────

  defp is_self?(%{author: author}, %State{bot_login: bot_login}) do
    not is_nil(bot_login) and author == bot_login
  end

  # ── Private: Cooldown ───────────────────────────────────────────

  defp thread_key(%{surface: surface, number: number}),
    do: "#{surface}:#{number}"

  defp on_cooldown?(thread_key, %State{cooldowns: cooldowns, cooldown_ms: cooldown_ms}) do
    case Map.get(cooldowns, thread_key) do
      nil ->
        false

      last_at ->
        now = System.monotonic_time(:millisecond)
        now - last_at < cooldown_ms
    end
  end

  defp record_cooldown(thread_key, %State{cooldowns: cooldowns} = state) do
    now = System.monotonic_time(:millisecond)
    %{state | cooldowns: Map.put(cooldowns, thread_key, now)}
  end

  # ── Private: Config ─────────────────────────────────────────────

  defp config(key, default) do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
