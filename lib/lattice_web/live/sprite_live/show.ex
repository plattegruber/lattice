defmodule LatticeWeb.SpriteLive.Show do
  @moduledoc """
  Sprite detail LiveView -- real-time view of a single Sprite's state.

  Displays:

  - **State comparison panel** -- observed vs desired state, drift highlighting,
    last reconciliation timestamp
  - **Event timeline** -- last N events streamed via PubSub
  - **Health & backoff info** -- health status, failure count, backoff duration
  - **Log lines** -- placeholder for future log streaming
  - **Approval queue** -- placeholder for future HITL approval workflow

  Subscribes to `sprites:<sprite_id>` PubSub topic on mount and renders
  projections of the event stream. No polling.
  """

  use LatticeWeb, :live_view

  alias Lattice.Events
  alias Lattice.Events.ApprovalNeeded
  alias Lattice.Events.HealthUpdate
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange
  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.Sprite
  alias Lattice.Sprites.State

  @max_events 50
  @refresh_interval_ms 30_000

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(%{"id" => sprite_id}, _session, socket) do
    case fetch_sprite_state(sprite_id) do
      {:ok, sprite_state} ->
        if connected?(socket) do
          Events.subscribe_sprite(sprite_id)
          Events.subscribe_fleet()
          schedule_refresh()
        end

        {:ok,
         socket
         |> assign(:page_title, "Sprite #{sprite_id}")
         |> assign(:sprite_id, sprite_id)
         |> assign(:sprite_state, sprite_state)
         |> assign(:events, [])
         |> assign(:last_reconciliation, nil)
         |> assign(:not_found, false)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> assign(:page_title, "Sprite Not Found")
         |> assign(:sprite_id, sprite_id)
         |> assign(:sprite_state, nil)
         |> assign(:events, [])
         |> assign(:last_reconciliation, nil)
         |> assign(:not_found, true)}
    end
  end

  # ── Event Handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info(%StateChange{} = event, socket) do
    socket =
      socket
      |> refresh_sprite_state()
      |> prepend_event(event)

    {:noreply, socket}
  end

  def handle_info(%ReconciliationResult{} = event, socket) do
    socket =
      socket
      |> refresh_sprite_state()
      |> prepend_event(event)
      |> assign(:last_reconciliation, event)

    {:noreply, socket}
  end

  def handle_info(%HealthUpdate{} = event, socket) do
    socket =
      socket
      |> refresh_sprite_state()
      |> prepend_event(event)

    {:noreply, socket}
  end

  def handle_info(%ApprovalNeeded{} = event, socket) do
    socket =
      socket
      |> refresh_sprite_state()
      |> prepend_event(event)

    {:noreply, socket}
  end

  def handle_info({:fleet_summary, _summary}, socket) do
    {:noreply, refresh_sprite_state(socket)}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh_sprite_state(socket)}
  end

  # Catch-all for unexpected PubSub messages
  def handle_info(_event, socket) do
    {:noreply, refresh_sprite_state(socket)}
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.breadcrumb sprite_id={@sprite_id} />

      <div :if={@not_found} class="text-center py-12">
        <.icon name="hero-exclamation-triangle" class="size-12 mx-auto mb-4 text-warning" />
        <p class="text-lg font-medium">Sprite not found</p>
        <p class="text-sm text-base-content/60 mt-1">
          No Sprite process with ID "{@sprite_id}" is currently running.
        </p>
        <div class="mt-6">
          <.link navigate={~p"/sprites"} class="btn btn-ghost">
            <.icon name="hero-arrow-left" class="size-4 mr-1" /> Back to Fleet
          </.link>
        </div>
      </div>

      <div :if={!@not_found} class="space-y-6">
        <.header>
          Sprite: {@sprite_id}
          <:subtitle>
            Real-time detail view for this Sprite process.
          </:subtitle>
        </.header>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.state_comparison_panel sprite_state={@sprite_state} />
          <.health_backoff_panel
            sprite_state={@sprite_state}
            last_reconciliation={@last_reconciliation}
          />
        </div>

        <.event_timeline events={@events} />

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <.log_lines_placeholder />
          <.approval_queue_placeholder />
        </div>
      </div>
    </div>
    """
  end

  # ── Functional Components ──────────────────────────────────────────

  attr :sprite_id, :string, required: true

  defp breadcrumb(assigns) do
    ~H"""
    <div class="text-sm breadcrumbs">
      <ul>
        <li>
          <.link navigate={~p"/sprites"} class="link link-hover">
            <.icon name="hero-squares-2x2" class="size-4 mr-1" /> Fleet
          </.link>
        </li>
        <li>
          <span class="font-medium">{@sprite_id}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :sprite_state, State, required: true

  defp state_comparison_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-arrows-right-left" class="size-5" /> State Comparison
        </h2>

        <div class="grid grid-cols-2 gap-4 mt-2">
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Observed
            </div>
            <div class="mt-1">
              <.state_badge state={@sprite_state.observed_state} />
            </div>
          </div>
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Desired
            </div>
            <div class="mt-1">
              <.state_badge state={@sprite_state.desired_state} />
            </div>
          </div>
        </div>

        <div :if={has_drift?(@sprite_state)} class="alert alert-warning mt-4">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>
            Drift detected: observed <.state_badge state={@sprite_state.observed_state} />
            differs from desired <.state_badge state={@sprite_state.desired_state} />
          </span>
        </div>

        <div :if={!has_drift?(@sprite_state)} class="alert alert-success mt-4">
          <.icon name="hero-check-circle" class="size-5" />
          <span>States are in sync.</span>
        </div>

        <div class="text-xs text-base-content/50 mt-2">
          Last updated: <.relative_time datetime={@sprite_state.updated_at} />
        </div>
      </div>
    </div>
    """
  end

  attr :sprite_state, State, required: true
  attr :last_reconciliation, ReconciliationResult, default: nil

  defp health_backoff_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-heart" class="size-5" /> Health & Backoff
        </h2>

        <div class="grid grid-cols-2 gap-4 mt-2">
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Health
            </div>
            <div class="mt-1">
              <.health_badge health={@sprite_state.health} />
            </div>
          </div>
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Failures
            </div>
            <div class="mt-1">
              <span class={[
                "badge badge-sm",
                failure_color(@sprite_state.failure_count)
              ]}>
                {@sprite_state.failure_count}
              </span>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4 mt-4">
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Backoff
            </div>
            <div class="mt-1 text-sm font-mono">
              {format_duration(@sprite_state.backoff_ms)}
            </div>
          </div>
          <div>
            <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide">
              Max Backoff
            </div>
            <div class="mt-1 text-sm font-mono">
              {format_duration(@sprite_state.max_backoff_ms)}
            </div>
          </div>
        </div>

        <div :if={@last_reconciliation} class="divider my-2"></div>
        <div :if={@last_reconciliation} class="text-sm">
          <div class="text-xs font-medium text-base-content/60 uppercase tracking-wide mb-1">
            Last Reconciliation
          </div>
          <div class="flex items-center gap-2">
            <.outcome_badge outcome={@last_reconciliation.outcome} />
            <span class="text-base-content/60 text-xs">
              {format_duration(@last_reconciliation.duration_ms)}
            </span>
          </div>
          <p :if={@last_reconciliation.details} class="text-xs text-base-content/50 mt-1">
            {@last_reconciliation.details}
          </p>
        </div>

        <div class="text-xs text-base-content/50 mt-2">
          Started: <.relative_time datetime={@sprite_state.started_at} />
        </div>
      </div>
    </div>
    """
  end

  attr :events, :list, required: true

  defp event_timeline(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-clock" class="size-5" /> Event Timeline
        </h2>

        <div :if={@events == []} class="text-center py-6 text-base-content/50">
          <.icon name="hero-inbox" class="size-8 mx-auto mb-2" />
          <p class="text-sm">No events yet. Events will appear here in real time.</p>
        </div>

        <div :if={@events != []} class="overflow-x-auto max-h-80 overflow-y-auto">
          <table class="table table-xs table-zebra">
            <thead class="sticky top-0 bg-base-200">
              <tr>
                <th>Time</th>
                <th>Type</th>
                <th>Details</th>
              </tr>
            </thead>
            <tbody id="event-timeline">
              <tr :for={event <- @events} id={"event-#{event_id(event)}"}>
                <td class="whitespace-nowrap font-mono text-xs">
                  <.relative_time datetime={event.timestamp} />
                </td>
                <td>
                  <.event_type_badge event={event} />
                </td>
                <td class="text-xs">
                  <.event_details event={event} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp log_lines_placeholder(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-document-text" class="size-5" /> Log Lines
        </h2>
        <div class="text-center py-6 text-base-content/50">
          <.icon name="hero-wrench-screwdriver" class="size-8 mx-auto mb-2" />
          <p class="text-sm">Log streaming will be available in a future release.</p>
        </div>
      </div>
    </div>
    """
  end

  defp approval_queue_placeholder(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-base">
          <.icon name="hero-shield-check" class="size-5" /> Approval Queue
        </h2>
        <div class="text-center py-6 text-base-content/50">
          <.icon name="hero-wrench-screwdriver" class="size-8 mx-auto mb-2" />
          <p class="text-sm">Approval workflows will be available in a future release.</p>
        </div>
      </div>
    </div>
    """
  end

  # ── Shared Functional Components ─────────────────────────────────

  attr :state, :atom, required: true

  defp state_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", state_color(@state)]}>
      {@state}
    </span>
    """
  end

  attr :health, :atom, required: true

  defp health_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", health_color(@health)]}>
      {@health}
    </span>
    """
  end

  attr :outcome, :atom, required: true

  defp outcome_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", outcome_color(@outcome)]}>
      {@outcome}
    </span>
    """
  end

  attr :event, :any, required: true

  defp event_type_badge(assigns) do
    ~H"""
    <span class={["badge badge-xs", event_type_color(@event)]}>
      {event_type_label(@event)}
    </span>
    """
  end

  attr :event, :any, required: true

  defp event_details(assigns) do
    ~H"""
    <span>{format_event_details(@event)}</span>
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

  defp fetch_sprite_state(sprite_id) do
    case FleetManager.get_sprite_pid(sprite_id) do
      {:ok, pid} -> Sprite.get_state(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp refresh_sprite_state(socket) do
    case fetch_sprite_state(socket.assigns.sprite_id) do
      {:ok, sprite_state} ->
        assign(socket, :sprite_state, sprite_state)

      {:error, :not_found} ->
        assign(socket, :not_found, true)
    end
  end

  defp prepend_event(socket, event) do
    events =
      [event | socket.assigns.events]
      |> Enum.take(@max_events)

    assign(socket, :events, events)
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp has_drift?(%State{observed_state: same, desired_state: same}), do: false
  defp has_drift?(%State{}), do: true

  # State colors (matching FleetLive)
  defp state_color(:hibernating), do: "badge-ghost"
  defp state_color(:waking), do: "badge-info"
  defp state_color(:ready), do: "badge-success"
  defp state_color(:busy), do: "badge-warning"
  defp state_color(:error), do: "badge-error"
  defp state_color(_), do: "badge-ghost"

  # Health colors (matching FleetLive)
  defp health_color(:healthy), do: "badge-success"
  defp health_color(:degraded), do: "badge-warning"
  defp health_color(:unhealthy), do: "badge-error"
  defp health_color(:unknown), do: "badge-ghost"
  defp health_color(_), do: "badge-ghost"

  # Outcome colors
  defp outcome_color(:success), do: "badge-success"
  defp outcome_color(:failure), do: "badge-error"
  defp outcome_color(:no_change), do: "badge-ghost"
  defp outcome_color(_), do: "badge-ghost"

  # Failure count coloring
  defp failure_color(0), do: "badge-success"
  defp failure_color(n) when n < 3, do: "badge-warning"
  defp failure_color(_), do: "badge-error"

  # Event type badge colors
  defp event_type_color(%StateChange{}), do: "badge-info"
  defp event_type_color(%ReconciliationResult{outcome: :success}), do: "badge-success"
  defp event_type_color(%ReconciliationResult{outcome: :failure}), do: "badge-error"
  defp event_type_color(%ReconciliationResult{}), do: "badge-ghost"
  defp event_type_color(%HealthUpdate{}), do: "badge-accent"
  defp event_type_color(%ApprovalNeeded{}), do: "badge-warning"
  defp event_type_color(_), do: "badge-ghost"

  # Event type labels
  defp event_type_label(%StateChange{}), do: "state_change"
  defp event_type_label(%ReconciliationResult{}), do: "reconciliation"
  defp event_type_label(%HealthUpdate{}), do: "health"
  defp event_type_label(%ApprovalNeeded{}), do: "approval"
  defp event_type_label(_), do: "unknown"

  # Format event details for the timeline
  defp format_event_details(%StateChange{} = e) do
    "#{e.from_state} -> #{e.to_state}" <> if(e.reason, do: " (#{e.reason})", else: "")
  end

  defp format_event_details(%ReconciliationResult{} = e) do
    base = "#{e.outcome} in #{format_duration(e.duration_ms)}"
    if e.details, do: "#{base}: #{e.details}", else: base
  end

  defp format_event_details(%HealthUpdate{} = e) do
    base = "#{e.status} (#{format_duration(e.check_duration_ms)})"
    if e.message, do: "#{base}: #{e.message}", else: base
  end

  defp format_event_details(%ApprovalNeeded{} = e) do
    "#{e.classification}: #{e.action}"
  end

  defp format_event_details(_), do: ""

  # Generate a unique ID for each event in the timeline
  defp event_id(event) do
    :erlang.phash2({event, System.unique_integer()})
  end

  # Format milliseconds to a human-readable duration
  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

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
