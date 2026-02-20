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
  alias Lattice.Ambient.SpriteDelegate
  alias Lattice.Capabilities.GitHub
  alias Lattice.Events

  defmodule State do
    @moduledoc false
    defstruct cooldowns: %{},
              active_tasks: %{},
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

  # Task completion: delegation or implementation returned a result
  def handle_info({ref, result}, %State{active_tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {task_entry, tasks} = Map.pop(tasks, ref)
    state = %{state | active_tasks: tasks}

    case task_entry do
      {:implement, event} ->
        handle_implementation_result(event, result, state)

      event when is_map(event) ->
        handle_delegation_result(event, result, state)
    end
  end

  # Task crash: delegation or implementation process died
  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{active_tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {task_entry, tasks} = Map.pop(tasks, ref)
    state = %{state | active_tasks: tasks}
    event = unwrap_task_event(task_entry)

    Logger.error("Ambient: task crashed for #{thread_key(event)}: #{inspect(reason)}")
    add_confused_reaction(event)
    {:noreply, state}
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

      # Step 2: Fetch thread context and classify
      thread_context = fetch_thread_context(event)
      classification = Claude.classify(event, thread_context)
      handle_classification(classification, event, thread_context, state)
    end
  end

  # ── Private: Classification Dispatch ───────────────────────────

  defp handle_classification({:ok, :implement, _}, event, thread_context, state) do
    Logger.info("Ambient: classify=implement on #{thread_key(event)}")

    task =
      Task.Supervisor.async_nolink(
        Lattice.Ambient.TaskSupervisor,
        fn -> SpriteDelegate.handle_implementation(event, thread_context) end
      )

    put_in(state.active_tasks[task.ref], {:implement, event})
  end

  defp handle_classification({:ok, :delegate, _}, event, thread_context, state) do
    Logger.info("Ambient: classify=delegate on #{thread_key(event)}")

    task =
      Task.Supervisor.async_nolink(
        Lattice.Ambient.TaskSupervisor,
        fn -> SpriteDelegate.handle(event, thread_context) end
      )

    put_in(state.active_tasks[task.ref], event)
  end

  defp handle_classification({:ok, :respond, response_text}, event, _thread_context, state) do
    Logger.info("Ambient: classify=respond on #{thread_key(event)}")
    post_response(event, response_text)
    record_cooldown(thread_key(event), state)
  end

  defp handle_classification({:ok, :react, _}, event, _thread_context, state) do
    Logger.info("Ambient: classify=react on #{thread_key(event)}")
    add_thumbsup_reaction(event)
    record_cooldown(thread_key(event), state)
  end

  defp handle_classification({:ok, :ignore, _}, event, _thread_context, state) do
    Logger.info("Ambient: classify=ignore on #{thread_key(event)}")
    add_thumbsup_reaction(event)
    state
  end

  defp handle_classification({:error, reason}, _event, _thread_context, state) do
    Logger.warning("Ambient: Claude classification failed: #{inspect(reason)}")
    state
  end

  # ── Private: Task Result Handlers ──────────────────────────────

  defp handle_delegation_result(event, result, state) do
    case result do
      {:ok, response_text} ->
        Logger.info("Ambient: delegation succeeded for #{thread_key(event)}")
        post_response(event, response_text)
        {:noreply, record_cooldown(thread_key(event), state)}

      {:error, reason} ->
        Logger.warning("Ambient: delegation failed for #{thread_key(event)}: #{inspect(reason)}")
        add_confused_reaction(event)
        {:noreply, state}
    end
  end

  defp handle_implementation_result(event, result, state) do
    case result do
      {:ok, branch_name} ->
        Logger.info(
          "Ambient: implementation succeeded for #{thread_key(event)}, branch=#{branch_name}"
        )

        create_pr_and_comment(event, branch_name)
        {:noreply, record_cooldown(thread_key(event), state)}

      {:error, :no_changes} ->
        Logger.warning("Ambient: implementation produced no changes for #{thread_key(event)}")

        post_error_comment(
          event,
          "I looked into this but couldn't produce any code changes. The issue may need more context or a different approach."
        )

        {:noreply, record_cooldown(thread_key(event), state)}

      {:error, reason} ->
        Logger.warning(
          "Ambient: implementation failed for #{thread_key(event)}: #{inspect(reason)}"
        )

        add_confused_reaction(event)

        post_error_comment(
          event,
          "I ran into an issue while trying to implement this: `#{inspect(reason)}`"
        )

        {:noreply, state}
    end
  end

  defp unwrap_task_event({:implement, event}), do: event
  defp unwrap_task_event(event) when is_map(event), do: event

  # ── Private: PR Creation ─────────────────────────────────────────

  defp create_pr_and_comment(event, branch_name) do
    number = event[:number]
    title = event[:title] || "Issue ##{number}"

    pr_attrs = %{
      title: "Fix ##{number}: #{title}",
      head: branch_name,
      base: "main",
      body:
        "Closes ##{number}\n\nAutomated implementation by Lattice.\n\n<!-- lattice:ambient:implement -->"
    }

    case GitHub.create_pull_request(pr_attrs) do
      {:ok, pr} ->
        pr_number = pr[:number] || pr.number
        pr_url = pr[:html_url] || pr[:url] || "##{pr_number}"

        Logger.info("Ambient: created PR ##{pr_number} for issue ##{number}")

        GitHub.create_comment(
          number,
          "I've created PR ##{pr_number}: #{pr_url}\n\n<!-- lattice:ambient:implement -->"
        )

      {:error, reason} ->
        Logger.error("Ambient: failed to create PR for issue ##{number}: #{inspect(reason)}")

        GitHub.create_comment(
          number,
          "I've pushed changes to branch `#{branch_name}` but PR creation failed: `#{inspect(reason)}`\n\n<!-- lattice:ambient:implement -->"
        )
    end
  rescue
    e ->
      Logger.error("Ambient: PR creation crashed for issue ##{event[:number]}: #{inspect(e)}")
  end

  defp post_error_comment(%{surface: :issue, number: number}, message)
       when not is_nil(number) do
    GitHub.create_comment(number, "#{message}\n\n<!-- lattice:ambient:implement -->")
  rescue
    e -> Logger.warning("Ambient: failed to post error comment: #{inspect(e)}")
  end

  defp post_error_comment(_, _), do: :ok

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

  defp add_confused_reaction(event) do
    case reaction_target(event) do
      {:comment, comment_id} ->
        GitHub.create_comment_reaction(comment_id, "confused")

      {:issue, number} ->
        GitHub.create_issue_reaction(number, "confused")

      {:review_comment, comment_id} ->
        GitHub.create_review_comment_reaction(comment_id, "confused")

      :none ->
        :ok
    end
  rescue
    e ->
      Logger.warning("Ambient: failed to add confused reaction: #{inspect(e)}")
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
    Logger.info("Ambient: posting comment (#{byte_size(body)} bytes) on issue ##{number}")

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
