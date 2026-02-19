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
  alias Lattice.Sprites.State
  alias LatticeWeb.Presence

  @refresh_interval_ms 30_000

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_fleet()
      schedule_refresh()

      Presence.track(self(), Presence.viewers_topic(), socket.id, %{
        page: :fleet,
        joined_at: DateTime.utc_now()
      })
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
  # results, approval events). Refresh sprite data so the
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
          <:col :let={{id, state}} label="Sprite">
            <.link navigate={~p"/sprites/#{id}"} class="link link-primary font-medium">
              {State.display_name(state)}
            </.link>
          </:col>
          <:col :let={{_id, state}} label="Status">
            <.state_badge state={state.status} />
          </:col>
          <:col :let={{_id, state}} label="Last Update">
            <.relative_time datetime={api_or_internal_timestamp(state)} />
          </:col>
        </.table>

        <div :if={@sprites == []} class="text-center py-12 text-base-content/60">
          <.icon name="hero-cube-transparent" class="size-12 mx-auto mb-4" />
          <p class="text-lg font-medium">No sprites in the fleet</p>
          <p class="text-sm mt-1">Sprites will appear here once configured.</p>
        </div>
      </div>

      <.capabilities_panel />
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

  defp state_color(:cold), do: "badge-ghost"
  defp state_color(:warm), do: "badge-info"
  defp state_color(:running), do: "badge-success"
  defp state_color(_), do: "badge-ghost"

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
    order = [:running, :warm, :cold]

    order
    |> Enum.filter(&Map.has_key?(by_state, &1))
    |> Enum.map(fn state -> {state, Map.get(by_state, state)} end)
  end

  defp api_or_internal_timestamp(state) do
    state.api_updated_at || state.last_active_at || state.updated_at
  end

  defp capabilities_panel(assigns) do
    ~H"""
    <div class="collapse collapse-arrow bg-base-200 border border-base-300">
      <input type="checkbox" />
      <div class="collapse-title font-medium">
        <.icon name="hero-signal" class="size-4" /> System Capabilities
      </div>
      <div class="collapse-content">
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3 pt-2">
          <.capability_card
            title="Fleet Management"
            status={:active}
            description="Real-time sprite lifecycle, observation, reconciliation"
          />
          <.capability_card
            title="Intent Pipeline"
            status={:active}
            description="Propose, classify, gate, approve, execute intents"
          />
          <.capability_card
            title="GitHub HITL"
            status={:active}
            description="Issue-based approval workflows, artifact tracking"
          />
          <.capability_card
            title="Safety & Audit"
            status={:active}
            description="Action classification, gating, audit logging"
          />
          <.capability_card
            title="Health Detection"
            status={:active}
            description="Anomaly detection, auto-remediation proposals"
          />
          <.capability_card
            title="Policy Engine"
            status={:active}
            description="Repo profiles, rules, path auto-approve"
          />
          <.capability_card
            title="Planning & Dialogue"
            status={:active}
            description="Structured plans, clarifying questions, plan execution"
          />
          <.capability_card
            title="Project Decomposition"
            status={:active}
            description="Epics, tasks, dependency tracking, progress rollup"
          />
          <.capability_card
            title="Doc Drift Detection"
            status={:active}
            description="Detects when code changes outpace documentation"
          />
          <.capability_card
            title="Exec Sessions"
            status={:active}
            description="WebSocket-backed command execution on sprites"
          />
          <.capability_card
            title="LLM Integration"
            status={:planned}
            description="AI-powered issue triage, plan generation, code review"
          />
          <.capability_card
            title="Figma UI"
            status={:planned}
            description="Custom visual design from Figma mockup"
          />
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :status, :atom, required: true
  attr :description, :string, required: true

  defp capability_card(assigns) do
    ~H"""
    <div class={[
      "card card-compact border",
      capability_card_class(@status)
    ]}>
      <div class="card-body">
        <div class="flex items-center gap-2">
          <span class={["size-2 rounded-full", capability_dot_class(@status)]} />
          <h3 class={["card-title text-sm", capability_text_class(@status)]}>
            {@title}
          </h3>
        </div>
        <p class={["text-xs", capability_desc_class(@status)]}>
          {@description}
        </p>
        <div class="mt-1">
          <span class={["badge badge-xs", capability_badge_class(@status)]}>
            {capability_label(@status)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp capability_card_class(:active), do: "border-base-300 bg-base-100"
  defp capability_card_class(:planned), do: "border-base-300/50 bg-base-200/50 opacity-60"

  defp capability_dot_class(:active), do: "bg-success"
  defp capability_dot_class(:planned), do: "bg-base-content/30"

  defp capability_text_class(:active), do: ""
  defp capability_text_class(:planned), do: "text-base-content/50"

  defp capability_desc_class(:active), do: "text-base-content/70"
  defp capability_desc_class(:planned), do: "text-base-content/40"

  defp capability_badge_class(:active), do: "badge-success"
  defp capability_badge_class(:planned), do: "badge-ghost"

  defp capability_label(:active), do: "Active"
  defp capability_label(:planned), do: "Planned"
end
