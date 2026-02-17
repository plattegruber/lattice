defmodule LatticeWeb.FleetLive do
  @moduledoc """
  Fleet dashboard LiveView — the NOC glass.

  Displays real-time status of all Sprites in the fleet. Subscribes to
  `sprites:fleet` PubSub topic on mount and updates the view whenever
  state changes, reconciliation results, or fleet summary updates arrive.

  Uses a periodic safety-net refresh (~30s) to catch any missed PubSub
  messages, per PHILOSOPHY.md's "Observable by Default" principle.
  """

  use LatticeWeb, :live_view

  alias Lattice.Events
  alias Lattice.Events.StateChange
  alias Lattice.Sprites.FleetManager

  @refresh_interval_ms 30_000

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_fleet()
      schedule_refresh()
    end

    sprites = FleetManager.list_sprites()
    summary = FleetManager.fleet_summary()

    {:ok,
     socket
     |> assign(:page_title, "Fleet")
     |> assign(:sprites, sprites)
     |> assign(:summary, summary)}
  end

  # ── Event Handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info({:fleet_summary, summary}, socket) do
    sprites = FleetManager.list_sprites()

    {:noreply,
     socket
     |> assign(:summary, summary)
     |> assign(:sprites, sprites)}
  end

  def handle_info(%StateChange{}, socket) do
    sprites = FleetManager.list_sprites()
    summary = FleetManager.fleet_summary()

    {:noreply,
     socket
     |> assign(:sprites, sprites)
     |> assign(:summary, summary)}
  end

  def handle_info(:refresh, socket) do
    sprites = FleetManager.list_sprites()
    summary = FleetManager.fleet_summary()
    schedule_refresh()

    {:noreply,
     socket
     |> assign(:sprites, sprites)
     |> assign(:summary, summary)}
  end

  # Catch-all for other PubSub events on the fleet topic (reconciliation
  # results, health updates, approval events). Refresh sprite data so the
  # dashboard stays current.
  def handle_info(_event, socket) do
    sprites = FleetManager.list_sprites()
    summary = FleetManager.fleet_summary()

    {:noreply,
     socket
     |> assign(:sprites, sprites)
     |> assign(:summary, summary)}
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Fleet Dashboard
        <:subtitle>
          Real-time status of all Sprites in the fleet.
        </:subtitle>
      </.header>

      <.fleet_summary summary={@summary} />

      <div class="overflow-x-auto">
        <.table
          id="sprites-table"
          rows={@sprites}
          row_id={fn {id, _state} -> "sprite-#{id}" end}
        >
          <:col :let={{id, _state}} label="Sprite ID">{id}</:col>
          <:col :let={{_id, state}} label="State">
            <.state_badge state={state.observed_state} />
          </:col>
          <:col :let={{_id, state}} label="Desired">
            <.state_badge state={state.desired_state} />
          </:col>
          <:col :let={{_id, state}} label="Health">
            <.health_badge health={state.health} />
          </:col>
          <:col :let={{_id, state}} label="Last Update">
            <.relative_time datetime={state.updated_at} />
          </:col>
          <:action :let={{id, _state}}>
            <.link navigate={~p"/sprites/#{id}"} class="link link-primary text-sm">
              View
            </.link>
          </:action>
        </.table>

        <div :if={@sprites == []} class="text-center py-12 text-base-content/60">
          <.icon name="hero-cube-transparent" class="size-12 mx-auto mb-4" />
          <p class="text-lg font-medium">No sprites in the fleet</p>
          <p class="text-sm mt-1">Sprites will appear here once configured.</p>
        </div>
      </div>
    </div>
    """
  end

  # ── Functional Components ──────────────────────────────────────────

  attr :summary, :map, required: true

  defp fleet_summary(assigns) do
    ~H"""
    <div class="stats shadow w-full">
      <div class="stat">
        <div class="stat-title">Total Sprites</div>
        <div class="stat-value">{@summary.total}</div>
      </div>
      <div :for={{state, count} <- sorted_states(@summary.by_state)} class="stat">
        <div class="stat-title">{format_state(state)}</div>
        <div class="stat-value text-lg">
          <.state_badge state={state} />
          <span class="ml-2">{count}</span>
        </div>
      </div>
    </div>
    """
  end

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

  attr :datetime, DateTime, required: true

  defp relative_time(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@datetime)} title={DateTime.to_iso8601(@datetime)}>
      {format_relative(@datetime)}
    </time>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp state_color(:hibernating), do: "badge-ghost"
  defp state_color(:waking), do: "badge-info"
  defp state_color(:ready), do: "badge-success"
  defp state_color(:busy), do: "badge-warning"
  defp state_color(:error), do: "badge-error"
  defp state_color(_), do: "badge-ghost"

  defp health_color(:healthy), do: "badge-success"
  defp health_color(:degraded), do: "badge-warning"
  defp health_color(:unhealthy), do: "badge-error"
  defp health_color(:unknown), do: "badge-ghost"
  defp health_color(_), do: "badge-ghost"

  defp format_state(state) do
    state
    |> to_string()
    |> String.capitalize()
  end

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

  defp sorted_states(by_state) do
    order = [:ready, :busy, :waking, :hibernating, :error]

    order
    |> Enum.filter(&Map.has_key?(by_state, &1))
    |> Enum.map(fn state -> {state, Map.get(by_state, state)} end)
  end
end
