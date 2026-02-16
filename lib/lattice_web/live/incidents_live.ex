defmodule LatticeWeb.IncidentsLive do
  @moduledoc """
  Incidents LiveView — real-time view of fleet-wide incidents.

  Displays a projection of error conditions across the fleet, including:

  - **Reconciliation failures** — sprites that fail reconciliation, with failure count and backoff info
  - **Error states** — sprites stuck in `:error` observed state
  - **Flapping detection** — sprites with rapid state transitions (>3 in 5 minutes)
  - **Backoff status** — sprites in backoff with duration and progress

  Subscribes to `sprites:fleet` PubSub topic on mount. Incidents are accumulated
  in LiveView assigns as a projection of the event stream — no separate data store.
  Auto-resolves incidents when conditions clear.
  """

  use LatticeWeb, :live_view

  alias Lattice.Events
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange
  alias Lattice.Sprites.FleetManager

  @max_incidents 100
  @max_transition_history 10
  @flapping_threshold 4
  @flapping_window_seconds 300
  @refresh_interval_ms 30_000

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_fleet()
      schedule_refresh()
    end

    sprites = FleetManager.list_sprites()

    {:ok,
     socket
     |> assign(:page_title, "Incidents")
     |> assign(:incidents, build_initial_incidents(sprites))
     |> assign(:transition_history, build_initial_transition_history(sprites))
     |> assign(:incident_count, 0)
     |> recompute_incident_count()}
  end

  # ── Event Handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info(%StateChange{} = event, socket) do
    socket =
      socket
      |> record_transition(event)
      |> detect_flapping(event.sprite_id)
      |> maybe_resolve_error_incident(event)
      |> maybe_add_error_incident(event)
      |> recompute_incident_count()

    {:noreply, socket}
  end

  def handle_info(%ReconciliationResult{outcome: :failure} = event, socket) do
    socket =
      socket
      |> add_or_update_reconciliation_failure(event)
      |> recompute_incident_count()

    {:noreply, socket}
  end

  def handle_info(%ReconciliationResult{outcome: :success} = event, socket) do
    socket =
      socket
      |> resolve_reconciliation_failure(event.sprite_id)
      |> recompute_incident_count()

    {:noreply, socket}
  end

  def handle_info({:fleet_summary, _summary}, socket) do
    socket =
      socket
      |> refresh_from_fleet()
      |> recompute_incident_count()

    {:noreply, socket}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()

    socket =
      socket
      |> refresh_from_fleet()
      |> expire_old_transitions()
      |> recompute_incident_count()

    {:noreply, socket}
  end

  # Catch-all for other PubSub events
  def handle_info(_event, socket) do
    {:noreply, socket}
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Incidents
        <:subtitle>
          Real-time incident tracking across the fleet.
        </:subtitle>
      </.header>

      <.incident_summary incidents={@incidents} />

      <div :if={active_incidents(@incidents) == []} class="text-center py-12 text-base-content/60">
        <.icon name="hero-check-circle" class="size-12 mx-auto mb-4 text-success" />
        <p class="text-lg font-medium">All clear</p>
        <p class="text-sm mt-1">No active incidents. The fleet is operating normally.</p>
      </div>

      <div :if={active_incidents(@incidents) != []} class="space-y-4">
        <div
          :for={incident <- sorted_incidents(@incidents)}
          id={"incident-#{incident.id}"}
          class="card bg-base-200 shadow-sm"
        >
          <div class="card-body p-4">
            <div class="flex items-start justify-between gap-4">
              <div class="flex items-center gap-3">
                <.severity_icon severity={incident.severity} />
                <div>
                  <div class="flex items-center gap-2">
                    <h3 class="font-medium text-sm">{incident.title}</h3>
                    <.severity_badge severity={incident.severity} />
                    <.type_badge type={incident.type} />
                  </div>
                  <p class="text-xs text-base-content/60 mt-0.5">{incident.description}</p>
                </div>
              </div>
              <div class="text-right shrink-0">
                <div class="text-xs text-base-content/50">
                  <.relative_time datetime={incident.started_at} />
                </div>
                <.link
                  navigate={~p"/sprites/#{incident.sprite_id}"}
                  class="link link-primary text-xs mt-1 inline-block"
                >
                  View Sprite
                </.link>
              </div>
            </div>

            <div :if={incident.type == :reconciliation_failure} class="mt-3">
              <.reconciliation_detail incident={incident} />
            </div>

            <div :if={incident.type == :backoff} class="mt-3">
              <.backoff_detail incident={incident} />
            </div>

            <div :if={incident.type == :flapping} class="mt-3">
              <.flapping_detail incident={incident} />
            </div>

            <div :if={incident.type == :error_state} class="mt-3">
              <.error_state_detail incident={incident} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Functional Components ──────────────────────────────────────────

  attr :incidents, :list, required: true

  defp incident_summary(assigns) do
    active = active_incidents(assigns.incidents)

    assigns =
      assigns
      |> assign(:active_count, length(active))
      |> assign(:critical_count, Enum.count(active, &(&1.severity == :critical)))
      |> assign(:warning_count, Enum.count(active, &(&1.severity == :warning)))
      |> assign(:info_count, Enum.count(active, &(&1.severity == :info)))

    ~H"""
    <div class="stats shadow w-full">
      <div class="stat">
        <div class="stat-title">Active Incidents</div>
        <div class={["stat-value", if(@active_count > 0, do: "text-error", else: "text-success")]}>
          {@active_count}
        </div>
      </div>
      <div class="stat">
        <div class="stat-title">Critical</div>
        <div class="stat-value text-lg text-error">{@critical_count}</div>
      </div>
      <div class="stat">
        <div class="stat-title">Warning</div>
        <div class="stat-value text-lg text-warning">{@warning_count}</div>
      </div>
      <div class="stat">
        <div class="stat-title">Info</div>
        <div class="stat-value text-lg text-info">{@info_count}</div>
      </div>
    </div>
    """
  end

  attr :severity, :atom, required: true

  defp severity_icon(assigns) do
    ~H"""
    <div :if={@severity == :critical}>
      <.icon name="hero-x-circle" class="size-6 text-error" />
    </div>
    <div :if={@severity == :warning}>
      <.icon name="hero-exclamation-triangle" class="size-6 text-warning" />
    </div>
    <div :if={@severity == :info}>
      <.icon name="hero-information-circle" class="size-6 text-info" />
    </div>
    """
  end

  attr :severity, :atom, required: true

  defp severity_badge(assigns) do
    ~H"""
    <span class={["badge badge-xs", severity_color(@severity)]}>
      {@severity}
    </span>
    """
  end

  attr :type, :atom, required: true

  defp type_badge(assigns) do
    ~H"""
    <span class="badge badge-xs badge-outline">
      {format_type(@type)}
    </span>
    """
  end

  attr :incident, :map, required: true

  defp reconciliation_detail(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-4 text-xs">
      <div>
        <span class="text-base-content/50">Failures:</span>
        <span class="font-mono font-medium">{@incident.failure_count}</span>
      </div>
      <div :if={@incident.details}>
        <span class="text-base-content/50">Last error:</span>
        <span class="font-mono">{@incident.details}</span>
      </div>
    </div>
    """
  end

  attr :incident, :map, required: true

  defp backoff_detail(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-4 text-xs">
      <div>
        <span class="text-base-content/50">Backoff:</span>
        <span class="font-mono font-medium">{format_duration(@incident.backoff_ms)}</span>
      </div>
      <div>
        <span class="text-base-content/50">Max backoff:</span>
        <span class="font-mono">{format_duration(@incident.max_backoff_ms)}</span>
      </div>
      <div>
        <span class="text-base-content/50">Failures:</span>
        <span class="font-mono font-medium">{@incident.failure_count}</span>
      </div>
    </div>
    """
  end

  attr :incident, :map, required: true

  defp flapping_detail(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-4 text-xs">
      <div>
        <span class="text-base-content/50">Transitions in last 5 min:</span>
        <span class="font-mono font-medium">{@incident.transition_count}</span>
      </div>
      <div>
        <span class="text-base-content/50">Threshold:</span>
        <span class="font-mono">{@incident.threshold}</span>
      </div>
    </div>
    """
  end

  attr :incident, :map, required: true

  defp error_state_detail(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-4 text-xs">
      <div>
        <span class="text-base-content/50">In error since:</span>
        <span class="font-mono font-medium">
          <.relative_time datetime={@incident.started_at} />
        </span>
      </div>
      <div :if={@incident.failure_count > 0}>
        <span class="text-base-content/50">Consecutive failures:</span>
        <span class="font-mono font-medium">{@incident.failure_count}</span>
      </div>
    </div>
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

  # ── Incident State Management ──────────────────────────────────────

  defp build_initial_incidents(sprites) do
    sprites
    |> Enum.flat_map(fn {sprite_id, state} -> incidents_from_state(sprite_id, state) end)
    |> Enum.take(@max_incidents)
  end

  defp incidents_from_state(sprite_id, state) do
    []
    |> maybe_add_error_state_incident(sprite_id, state)
    |> maybe_add_backoff_incident(sprite_id, state)
  end

  defp maybe_add_error_state_incident(incidents, sprite_id, %{observed_state: :error} = state) do
    incident = %{
      id: "error-#{sprite_id}",
      type: :error_state,
      severity: :critical,
      sprite_id: sprite_id,
      title: "Sprite #{sprite_id} in error state",
      description: "Sprite is in :error observed state and needs attention.",
      started_at: state.updated_at,
      failure_count: state.failure_count
    }

    [incident | incidents]
  end

  defp maybe_add_error_state_incident(incidents, _sprite_id, _state), do: incidents

  defp maybe_add_backoff_incident(incidents, sprite_id, %{failure_count: fc} = state)
       when fc > 0 do
    incident = %{
      id: "backoff-#{sprite_id}",
      type: :backoff,
      severity: backoff_severity(state.backoff_ms, state.max_backoff_ms),
      sprite_id: sprite_id,
      title: "Sprite #{sprite_id} in backoff",
      description: "Sprite is backing off after #{fc} consecutive failure(s).",
      started_at: state.updated_at,
      failure_count: fc,
      backoff_ms: state.backoff_ms,
      max_backoff_ms: state.max_backoff_ms
    }

    [incident | incidents]
  end

  defp maybe_add_backoff_incident(incidents, _sprite_id, _state), do: incidents

  defp build_initial_transition_history(sprites) do
    Map.new(sprites, fn {sprite_id, _state} -> {sprite_id, []} end)
  end

  defp record_transition(socket, %StateChange{} = event) do
    history = socket.assigns.transition_history
    sprite_transitions = Map.get(history, event.sprite_id, [])

    updated =
      [{event.from_state, event.to_state, event.timestamp} | sprite_transitions]
      |> Enum.take(@max_transition_history)

    assign(socket, :transition_history, Map.put(history, event.sprite_id, updated))
  end

  defp detect_flapping(socket, sprite_id) do
    history = socket.assigns.transition_history
    transitions = Map.get(history, sprite_id, [])
    now = DateTime.utc_now()

    recent_count =
      Enum.count(transitions, fn {_from, _to, ts} ->
        DateTime.diff(now, ts, :second) <= @flapping_window_seconds
      end)

    flapping_id = "flapping-#{sprite_id}"

    if recent_count >= @flapping_threshold do
      apply_flapping_incident(socket, sprite_id, flapping_id, recent_count, now)
    else
      updated = Enum.reject(socket.assigns.incidents, &(&1.id == flapping_id))
      assign(socket, :incidents, updated)
    end
  end

  defp apply_flapping_incident(socket, sprite_id, flapping_id, recent_count, now) do
    incidents = socket.assigns.incidents
    existing = Enum.find(incidents, &(&1.id == flapping_id))

    if existing do
      updated =
        Enum.map(incidents, fn
          %{id: ^flapping_id} = inc -> %{inc | transition_count: recent_count}
          inc -> inc
        end)

      assign(socket, :incidents, updated)
    else
      incident = %{
        id: flapping_id,
        type: :flapping,
        severity: :warning,
        sprite_id: sprite_id,
        title: "Sprite #{sprite_id} is flapping",
        description:
          "#{recent_count} state transitions in the last 5 minutes (threshold: #{@flapping_threshold}).",
        started_at: now,
        transition_count: recent_count,
        threshold: @flapping_threshold
      }

      assign(socket, :incidents, add_incident(incidents, incident))
    end
  end

  defp maybe_resolve_error_incident(socket, %StateChange{to_state: to_state} = event)
       when to_state != :error do
    incidents =
      Enum.reject(socket.assigns.incidents, &(&1.id == "error-#{event.sprite_id}"))

    assign(socket, :incidents, incidents)
  end

  defp maybe_resolve_error_incident(socket, _event), do: socket

  defp maybe_add_error_incident(socket, %StateChange{to_state: :error} = event) do
    incidents = socket.assigns.incidents
    existing = Enum.find(incidents, &(&1.id == "error-#{event.sprite_id}"))

    if existing do
      socket
    else
      incident = %{
        id: "error-#{event.sprite_id}",
        type: :error_state,
        severity: :critical,
        sprite_id: event.sprite_id,
        title: "Sprite #{event.sprite_id} in error state",
        description:
          "Sprite transitioned to :error from :#{event.from_state}." <>
            if(event.reason, do: " Reason: #{event.reason}", else: ""),
        started_at: event.timestamp,
        failure_count: 0
      }

      assign(socket, :incidents, add_incident(incidents, incident))
    end
  end

  defp maybe_add_error_incident(socket, _event), do: socket

  defp add_or_update_reconciliation_failure(socket, %ReconciliationResult{} = event) do
    incidents = socket.assigns.incidents
    incident_id = "reconciliation-#{event.sprite_id}"
    existing = Enum.find(incidents, &(&1.id == incident_id))

    if existing do
      updated =
        Enum.map(incidents, fn
          %{id: ^incident_id} = inc ->
            %{
              inc
              | failure_count: inc.failure_count + 1,
                details: event.details,
                description:
                  "Reconciliation failing — #{inc.failure_count + 1} consecutive failure(s)."
            }

          inc ->
            inc
        end)

      assign(socket, :incidents, updated)
    else
      incident = %{
        id: incident_id,
        type: :reconciliation_failure,
        severity: :critical,
        sprite_id: event.sprite_id,
        title: "Sprite #{event.sprite_id} reconciliation failing",
        description: "Reconciliation failing — 1 consecutive failure(s).",
        started_at: event.timestamp,
        failure_count: 1,
        details: event.details
      }

      assign(socket, :incidents, add_incident(incidents, incident))
    end
  end

  defp resolve_reconciliation_failure(socket, sprite_id) do
    incidents =
      Enum.reject(
        socket.assigns.incidents,
        &(&1.id == "reconciliation-#{sprite_id}")
      )

    assign(socket, :incidents, incidents)
  end

  defp refresh_from_fleet(socket) do
    sprites = FleetManager.list_sprites()

    # Rebuild backoff and error incidents from current fleet state,
    # preserving reconciliation failure and flapping incidents
    preserved =
      Enum.filter(socket.assigns.incidents, fn inc ->
        inc.type in [:reconciliation_failure, :flapping]
      end)

    fleet_incidents =
      sprites
      |> Enum.flat_map(fn {sprite_id, state} -> incidents_from_state(sprite_id, state) end)

    # Merge: fleet-derived incidents replace stale ones, preserved ones stay
    fleet_ids = MapSet.new(fleet_incidents, & &1.id)
    preserved = Enum.reject(preserved, &MapSet.member?(fleet_ids, &1.id))

    combined =
      (fleet_incidents ++ preserved)
      |> Enum.take(@max_incidents)

    assign(socket, :incidents, combined)
  end

  defp expire_old_transitions(socket) do
    now = DateTime.utc_now()

    updated =
      Map.new(socket.assigns.transition_history, fn {sprite_id, transitions} ->
        filtered =
          Enum.filter(transitions, fn {_from, _to, ts} ->
            DateTime.diff(now, ts, :second) <= @flapping_window_seconds
          end)

        {sprite_id, filtered}
      end)

    assign(socket, :transition_history, updated)
  end

  defp add_incident(incidents, incident) do
    [incident | incidents]
    |> Enum.take(@max_incidents)
  end

  defp recompute_incident_count(socket) do
    count = length(active_incidents(socket.assigns.incidents))
    assign(socket, :incident_count, count)
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp active_incidents(incidents), do: incidents

  defp sorted_incidents(incidents) do
    incidents
    |> active_incidents()
    |> Enum.sort_by(
      fn inc -> {severity_order(inc.severity), inc.started_at} end,
      fn {sev_a, ts_a}, {sev_b, ts_b} ->
        if sev_a == sev_b do
          DateTime.compare(ts_a, ts_b) == :gt
        else
          sev_a < sev_b
        end
      end
    )
  end

  defp severity_order(:critical), do: 0
  defp severity_order(:warning), do: 1
  defp severity_order(:info), do: 2

  defp severity_color(:critical), do: "badge-error"
  defp severity_color(:warning), do: "badge-warning"
  defp severity_color(:info), do: "badge-info"

  defp backoff_severity(backoff_ms, max_backoff_ms) when backoff_ms >= max_backoff_ms,
    do: :critical

  defp backoff_severity(backoff_ms, _max) when backoff_ms > 5_000, do: :warning
  defp backoff_severity(_backoff_ms, _max), do: :info

  defp format_type(:reconciliation_failure), do: "reconciliation"
  defp format_type(:error_state), do: "error state"
  defp format_type(:flapping), do: "flapping"
  defp format_type(:backoff), do: "backoff"

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

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
