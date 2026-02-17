defmodule LatticeWeb.IntentLive.Show do
  @moduledoc """
  Intent detail LiveView — real-time view of a single Intent's lifecycle.

  Displays:

  - **Intent details panel** — kind, state, classification, source, payload,
    affected resources, expected side effects, rollback strategy
  - **Lifecycle timeline** — all transitions with timestamps, actors, and reasons
  - **Artifacts section** — logs, PR URLs, deploy IDs, outputs
  - **Action buttons** — Approve, Reject, Cancel — visibility based on current
    state and valid transitions

  Subscribes to `"intents:<intent_id>"` and `"intents"` PubSub topics on mount
  and renders projections of the event stream. No polling.
  """

  use LatticeWeb, :live_view

  alias Lattice.Events
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Lifecycle
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store

  @refresh_interval_ms 30_000

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(%{"id" => intent_id}, _session, socket) do
    case Store.get(intent_id) do
      {:ok, intent} ->
        if connected?(socket) do
          Events.subscribe_intent(intent_id)
          Events.subscribe_intents()
          schedule_refresh()
        end

        {:ok,
         socket
         |> assign(:page_title, "Intent #{truncate_id(intent_id)}")
         |> assign(:intent_id, intent_id)
         |> assign(:intent, intent)
         |> assign(:not_found, false)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> assign(:page_title, "Intent Not Found")
         |> assign(:intent_id, intent_id)
         |> assign(:intent, nil)
         |> assign(:not_found, true)}
    end
  end

  # ── Event Handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info({:intent_transitioned, %Intent{id: id}}, %{assigns: %{intent_id: id}} = socket) do
    {:noreply, refresh_intent(socket)}
  end

  def handle_info({:intent_approved, %Intent{id: id}}, %{assigns: %{intent_id: id}} = socket) do
    {:noreply, refresh_intent(socket)}
  end

  def handle_info({:intent_rejected, %Intent{id: id}}, %{assigns: %{intent_id: id}} = socket) do
    {:noreply, refresh_intent(socket)}
  end

  def handle_info({:intent_canceled, %Intent{id: id}}, %{assigns: %{intent_id: id}} = socket) do
    {:noreply, refresh_intent(socket)}
  end

  def handle_info(
        {:intent_awaiting_approval, %Intent{id: id}},
        %{assigns: %{intent_id: id}} = socket
      ) do
    {:noreply, refresh_intent(socket)}
  end

  def handle_info({:intent_classified, %Intent{id: id}}, %{assigns: %{intent_id: id}} = socket) do
    {:noreply, refresh_intent(socket)}
  end

  def handle_info({:intent_proposed, %Intent{id: id}}, %{assigns: %{intent_id: id}} = socket) do
    {:noreply, refresh_intent(socket)}
  end

  def handle_info(
        {:intent_artifact_added, %Intent{id: id}, _artifact},
        %{assigns: %{intent_id: id}} = socket
      ) do
    {:noreply, refresh_intent(socket)}
  end

  def handle_info({:intent_created, %Intent{id: id}}, %{assigns: %{intent_id: id}} = socket) do
    {:noreply, refresh_intent(socket)}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh_intent(socket)}
  end

  # Catch-all for other PubSub events (including events for other intents)
  def handle_info(_event, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("approve", _params, socket) do
    actor = get_actor(socket)

    case Pipeline.approve(socket.assigns.intent_id, actor: actor, reason: "approved via UI") do
      {:ok, _intent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Intent approved.")
         |> refresh_intent()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to approve: #{inspect(reason)}")}
    end
  end

  def handle_event("reject", _params, socket) do
    actor = get_actor(socket)

    case Pipeline.reject(socket.assigns.intent_id, actor: actor, reason: "rejected via UI") do
      {:ok, _intent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Intent rejected.")
         |> refresh_intent()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to reject: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel", _params, socket) do
    actor = get_actor(socket)

    case Pipeline.cancel(socket.assigns.intent_id, actor: actor, reason: "canceled via UI") do
      {:ok, _intent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Intent canceled.")
         |> refresh_intent()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel: #{inspect(reason)}")}
    end
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.breadcrumb intent_id={@intent_id} />

      <div :if={@not_found} class="text-center py-12">
        <.icon name="hero-exclamation-triangle" class="size-12 mx-auto mb-4 text-warning" />
        <p class="text-lg font-medium">Intent not found</p>
        <p class="text-sm text-base-content/60 mt-1">
          No intent with ID "{truncate_id(@intent_id)}" exists in the store.
        </p>
        <div class="mt-6">
          <.link navigate={~p"/intents"} class="btn btn-ghost">
            <.icon name="hero-arrow-left" class="size-4 mr-1" /> Back to Intents
          </.link>
        </div>
      </div>

      <div :if={!@not_found} class="space-y-6">
        <.header>
          Intent: {truncate_id(@intent.id)}
          <:subtitle>
            {@intent.summary}
          </:subtitle>
        </.header>

        <.action_buttons intent={@intent} />

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.intent_details_panel intent={@intent} />
          <.classification_panel intent={@intent} />
        </div>

        <.task_details_panel :if={Intent.task?(@intent)} intent={@intent} />

        <.payload_panel intent={@intent} />

        <.lifecycle_timeline intent={@intent} />

        <.artifacts_panel intent={@intent} />

        <div :if={@intent.source.type == :sprite} class="mt-2">
          <.link
            navigate={~p"/sprites/#{@intent.source.id}"}
            class="link link-primary text-sm"
          >
            <.icon name="hero-cpu-chip" class="size-4 inline" />
            View source Sprite: {@intent.source.id}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # ── Functional Components ──────────────────────────────────────────

  attr :intent_id, :string, required: true

  defp breadcrumb(assigns) do
    ~H"""
    <div class="text-sm breadcrumbs">
      <ul>
        <li>
          <.link navigate={~p"/intents"} class="link link-hover">
            <.icon name="hero-clipboard-document-list" class="size-4 mr-1" /> Intents
          </.link>
        </li>
        <li>
          <span class="font-medium font-mono">{truncate_id(@intent_id)}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :intent, Intent, required: true

  defp action_buttons(assigns) do
    valid = Lifecycle.valid_transitions(assigns.intent.state)
    assigns = assign(assigns, :valid_transitions, valid)

    ~H"""
    <div :if={@valid_transitions != []} class="flex flex-wrap gap-2">
      <button
        :if={:approved in @valid_transitions and @intent.state == :awaiting_approval}
        phx-click="approve"
        data-confirm="Are you sure you want to approve this intent?"
        class="btn btn-success btn-sm"
      >
        <.icon name="hero-check-circle" class="size-4" /> Approve
      </button>
      <button
        :if={:rejected in @valid_transitions}
        phx-click="reject"
        data-confirm="Are you sure you want to reject this intent?"
        class="btn btn-error btn-sm"
      >
        <.icon name="hero-x-circle" class="size-4" /> Reject
      </button>
      <button
        :if={:canceled in @valid_transitions}
        phx-click="cancel"
        data-confirm="Are you sure you want to cancel this intent?"
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-no-symbol" class="size-4" /> Cancel
      </button>
    </div>
    """
  end

  attr :intent, Intent, required: true

  defp intent_details_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-information-circle" class="size-5" /> Details
        </h2>

        <div class="grid grid-cols-2 gap-4 mt-2">
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Kind
            </div>
            <div class="mt-1">
              <.intent_kind_badge kind={@intent.kind} />
            </div>
          </div>
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              State
            </div>
            <div class="mt-1">
              <.intent_state_badge state={@intent.state} />
            </div>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4 mt-4">
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Source
            </div>
            <div class="mt-1 text-sm font-mono">
              {format_source(@intent.source)}
            </div>
          </div>
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              ID
            </div>
            <div class="mt-1 text-xs font-mono select-all">
              {@intent.id}
            </div>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4 mt-4">
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Created
            </div>
            <div class="mt-1 text-sm">
              <.relative_time datetime={@intent.inserted_at} />
            </div>
          </div>
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Updated
            </div>
            <div class="mt-1 text-sm">
              <.relative_time datetime={@intent.updated_at} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :intent, Intent, required: true

  defp classification_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-shield-check" class="size-5" /> Classification & Safety
        </h2>

        <div class="grid grid-cols-2 gap-4 mt-2">
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Classification
            </div>
            <div class="mt-1">
              <.classification_badge classification={@intent.classification} />
            </div>
          </div>
          <div :if={@intent.classified_at}>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Classified At
            </div>
            <div class="mt-1 text-sm">
              <.relative_time datetime={@intent.classified_at} />
            </div>
          </div>
        </div>

        <div :if={@intent.affected_resources != []} class="mt-4">
          <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide mb-1">
            Affected Resources
          </div>
          <div class="flex flex-wrap gap-1">
            <span
              :for={resource <- @intent.affected_resources}
              class="badge badge-xs badge-outline"
            >
              {resource}
            </span>
          </div>
        </div>

        <div :if={@intent.expected_side_effects != []} class="mt-4">
          <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide mb-1">
            Expected Side Effects
          </div>
          <ul class="text-xs text-base-content/70 space-y-0.5">
            <li :for={effect <- @intent.expected_side_effects}>
              - {effect}
            </li>
          </ul>
        </div>

        <div :if={@intent.rollback_strategy} class="mt-4">
          <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide mb-1">
            Rollback Strategy
          </div>
          <p class="text-xs text-base-content/70">{@intent.rollback_strategy}</p>
        </div>
      </div>
    </div>
    """
  end

  attr :intent, Intent, required: true

  defp task_details_panel(assigns) do
    payload = assigns.intent.payload
    artifacts = Map.get(assigns.intent.metadata, :artifacts, [])

    pr_artifact =
      Enum.find(artifacts, fn a ->
        Map.get(a, :type) in ["pr_url", :pr_url]
      end)

    pr_url =
      if pr_artifact,
        do: get_in(pr_artifact, [:data, "url"]) || get_in(pr_artifact, [:data, :url])

    assigns =
      assigns
      |> assign(:task_payload, payload)
      |> assign(:pr_url, pr_url)

    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-command-line" class="size-5" /> Task Details
        </h2>

        <div class="grid grid-cols-2 lg:grid-cols-3 gap-4 mt-2">
          <div :if={@task_payload["sprite_name"]}>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Sprite
            </div>
            <div class="mt-1 text-sm font-mono">{@task_payload["sprite_name"]}</div>
          </div>
          <div :if={@task_payload["repo"]}>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Repository
            </div>
            <div class="mt-1 text-sm font-mono">{@task_payload["repo"]}</div>
          </div>
          <div :if={@task_payload["task_kind"]}>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Task Kind
            </div>
            <div class="mt-1">
              <span class="badge badge-sm badge-outline">{@task_payload["task_kind"]}</span>
            </div>
          </div>
          <div :if={@task_payload["base_branch"]}>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Base Branch
            </div>
            <div class="mt-1 text-sm font-mono">{@task_payload["base_branch"]}</div>
          </div>
          <div :if={@task_payload["pr_title"]}>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              PR Title
            </div>
            <div class="mt-1 text-sm">{@task_payload["pr_title"]}</div>
          </div>
        </div>

        <div :if={@task_payload["instructions"]} class="mt-4">
          <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide mb-1">
            Instructions
          </div>
          <div class="bg-base-300 rounded-lg p-3">
            <p class="text-sm whitespace-pre-wrap">{@task_payload["instructions"]}</p>
          </div>
        </div>

        <div :if={@pr_url} class="mt-4">
          <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide mb-1">
            Pull Request
          </div>
          <a href={@pr_url} target="_blank" rel="noopener" class="link link-primary text-sm">
            <.icon name="hero-arrow-top-right-on-square" class="size-4 inline" />
            {@pr_url}
          </a>
        </div>
      </div>
    </div>
    """
  end

  attr :intent, Intent, required: true

  defp payload_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-code-bracket" class="size-5" /> Payload
        </h2>

        <div class="mt-2 bg-base-300 rounded-lg p-3 overflow-x-auto">
          <pre class="text-xs font-mono whitespace-pre-wrap">{format_payload(@intent.payload)}</pre>
        </div>

        <div :if={@intent.result} class="mt-4">
          <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide mb-1">
            Result
          </div>
          <div class="bg-base-300 rounded-lg p-3 overflow-x-auto">
            <pre class="text-xs font-mono whitespace-pre-wrap">{format_payload(@intent.result)}</pre>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :intent, Intent, required: true

  defp lifecycle_timeline(assigns) do
    history = Enum.reverse(assigns.intent.transition_log)
    assigns = assign(assigns, :history, history)

    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-clock" class="size-5" /> Lifecycle Timeline
        </h2>

        <div :if={@history == []} class="text-center py-6 text-base-content/50">
          <.icon name="hero-inbox" class="size-8 mx-auto mb-2" />
          <p class="text-sm">No transitions yet.</p>
        </div>

        <div :if={@history != []} class="overflow-x-auto">
          <table class="table table-xs table-zebra">
            <thead>
              <tr>
                <th>Time</th>
                <th>From</th>
                <th>To</th>
                <th>Actor</th>
                <th>Reason</th>
              </tr>
            </thead>
            <tbody id="timeline">
              <tr :for={entry <- @history} id={"transition-#{transition_id(entry)}"}>
                <td class="whitespace-nowrap font-mono text-xs">
                  <.relative_time datetime={entry.timestamp} />
                </td>
                <td>
                  <.intent_state_badge state={entry.from} />
                </td>
                <td>
                  <.intent_state_badge state={entry.to} />
                </td>
                <td class="text-xs text-base-content/60">
                  {format_actor(entry.actor)}
                </td>
                <td class="text-xs text-base-content/60">
                  {entry.reason || "-"}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :intent, Intent, required: true

  defp artifacts_panel(assigns) do
    artifacts = Map.get(assigns.intent.metadata, :artifacts, [])
    assigns = assign(assigns, :artifacts, artifacts)

    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-document-text" class="size-5" /> Artifacts
        </h2>

        <div :if={@artifacts == []} class="text-center py-6 text-base-content/50">
          <.icon name="hero-inbox" class="size-8 mx-auto mb-2" />
          <p class="text-sm">No artifacts recorded yet.</p>
        </div>

        <div :if={@artifacts != []} class="space-y-3">
          <div
            :for={artifact <- @artifacts}
            class="bg-base-300 rounded-lg p-3"
          >
            <div class="flex items-center gap-2 mb-1">
              <span class="badge badge-xs badge-outline">
                {Map.get(artifact, :type, "unknown")}
              </span>
              <span :if={Map.get(artifact, :added_at)} class="text-xs text-base-content/50">
                <.relative_time datetime={artifact.added_at} />
              </span>
            </div>
            <pre class="text-xs font-mono whitespace-pre-wrap">{format_payload(Map.get(artifact, :data, artifact))}</pre>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Shared Functional Components ──────────────────────────────────

  attr :state, :atom, required: true

  defp intent_state_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", intent_state_color(@state)]}>
      {@state}
    </span>
    """
  end

  attr :kind, :atom, required: true

  defp intent_kind_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm badge-outline", intent_kind_color(@kind)]}>
      {format_kind(@kind)}
    </span>
    """
  end

  attr :classification, :atom, required: true

  defp classification_badge(assigns) do
    ~H"""
    <span :if={@classification} class={["badge badge-sm", classification_color(@classification)]}>
      {@classification}
    </span>
    <span :if={!@classification} class="badge badge-sm badge-ghost">
      pending
    </span>
    """
  end

  attr :datetime, DateTime, required: true

  defp relative_time(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@datetime)} title={DateTime.to_iso8601(@datetime)}>
      {format_relative(@datetime)}
    </time>
    """
  end

  # ── Private Helpers ────────────────────────────────────────────────

  defp refresh_intent(socket) do
    case Store.get(socket.assigns.intent_id) do
      {:ok, intent} ->
        assign(socket, :intent, intent)

      {:error, :not_found} ->
        assign(socket, :not_found, true)
    end
  end

  defp get_actor(socket) do
    case Map.get(socket.assigns, :current_operator) do
      nil -> :operator
      operator -> operator.id || :operator
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp truncate_id("int_" <> rest), do: "int_" <> String.slice(rest, 0, 8) <> "..."
  defp truncate_id(id), do: String.slice(id, 0, 16) <> "..."

  defp format_source(%{type: type, id: id}), do: "#{type}:#{id}"
  defp format_source(_), do: "unknown"

  defp format_kind(:action), do: "Action"
  defp format_kind(:inquiry), do: "Inquiry"
  defp format_kind(:maintenance), do: "Maintenance"
  defp format_kind(kind), do: to_string(kind) |> String.capitalize()

  defp format_actor(nil), do: "-"
  defp format_actor(:pipeline), do: "pipeline"
  defp format_actor(:system), do: "system"
  defp format_actor(actor) when is_atom(actor), do: to_string(actor)
  defp format_actor(actor) when is_binary(actor), do: actor
  defp format_actor(actor), do: inspect(actor)

  defp format_payload(payload) when is_map(payload) do
    Jason.encode!(payload, pretty: true)
  rescue
    _ -> inspect(payload, pretty: true)
  end

  defp format_payload(payload), do: inspect(payload, pretty: true)

  defp transition_id(entry) do
    :erlang.phash2({entry.from, entry.to, entry.timestamp})
  end

  defp intent_state_color(:proposed), do: "badge-ghost"
  defp intent_state_color(:classified), do: "badge-info"
  defp intent_state_color(:awaiting_approval), do: "badge-warning"
  defp intent_state_color(:approved), do: "badge-success"
  defp intent_state_color(:running), do: "badge-info"
  defp intent_state_color(:completed), do: "badge-success"
  defp intent_state_color(:failed), do: "badge-error"
  defp intent_state_color(:rejected), do: "badge-error"
  defp intent_state_color(:canceled), do: "badge-ghost"
  defp intent_state_color(_), do: "badge-ghost"

  defp intent_kind_color(:action), do: "badge-primary"
  defp intent_kind_color(:inquiry), do: "badge-secondary"
  defp intent_kind_color(:maintenance), do: "badge-accent"
  defp intent_kind_color(_), do: "badge-ghost"

  defp classification_color(:safe), do: "badge-success"
  defp classification_color(:controlled), do: "badge-warning"
  defp classification_color(:dangerous), do: "badge-error"
  defp classification_color(_), do: "badge-ghost"

  defp format_relative(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
