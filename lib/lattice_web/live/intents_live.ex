defmodule LatticeWeb.IntentsLive do
  @moduledoc """
  Intent dashboard LiveView — the governance glass.

  Displays real-time status of all Intents in the system. Subscribes to
  `"intents:all"` and `"intents"` PubSub topics on mount and updates the
  view whenever intent state changes arrive.

  Uses a periodic safety-net refresh (~30s) to catch any missed PubSub
  messages, per PHILOSOPHY.md's "Observable by Default" principle.
  """

  use LatticeWeb, :live_view

  alias Lattice.Events
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Lifecycle
  alias Lattice.Intents.Store

  @refresh_interval_ms 30_000

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_all_intents()
      Events.subscribe_intents()
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Intents")
     |> assign(:filter_kind, "all")
     |> assign(:filter_state, "all")
     |> assign(:filter_classification, "all")
     |> assign(:sort_by, "newest")
     |> assign_intents()}
  end

  # ── Event Handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info({:intent_created, _intent}, socket) do
    {:noreply, assign_intents(socket)}
  end

  def handle_info({:intent_transitioned, _intent}, socket) do
    {:noreply, assign_intents(socket)}
  end

  def handle_info({:intent_proposed, _intent}, socket) do
    {:noreply, assign_intents(socket)}
  end

  def handle_info({:intent_classified, _intent}, socket) do
    {:noreply, assign_intents(socket)}
  end

  def handle_info({:intent_approved, _intent}, socket) do
    {:noreply, assign_intents(socket)}
  end

  def handle_info({:intent_rejected, _intent}, socket) do
    {:noreply, assign_intents(socket)}
  end

  def handle_info({:intent_canceled, _intent}, socket) do
    {:noreply, assign_intents(socket)}
  end

  def handle_info({:intent_awaiting_approval, _intent}, socket) do
    {:noreply, assign_intents(socket)}
  end

  def handle_info({:intent_artifact_added, _intent, _artifact}, socket) do
    {:noreply, assign_intents(socket)}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_intents(socket)}
  end

  # Catch-all for other PubSub events
  def handle_info(_event, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    {:noreply,
     socket
     |> assign(:filter_kind, kind)
     |> assign_derived()}
  end

  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply,
     socket
     |> assign(:filter_state, state)
     |> assign_derived()}
  end

  def handle_event("filter_classification", %{"classification" => classification}, socket) do
    {:noreply,
     socket
     |> assign(:filter_classification, classification)
     |> assign_derived()}
  end

  def handle_event("sort", %{"sort_by" => sort_by}, socket) do
    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> assign_derived()}
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Intents
        <:subtitle>
          Real-time view of all intents in the system — proposals, approvals, and execution.
        </:subtitle>
      </.header>

      <.intent_summary_stats
        total={length(@all_intents)}
        by_state={@by_state}
        by_kind={@by_kind}
      />

      <.filters
        filter_kind={@filter_kind}
        filter_state={@filter_state}
        filter_classification={@filter_classification}
        sort_by={@sort_by}
      />

      <div :if={@filtered_intents == []} class="text-center py-12 text-base-content/60">
        <.icon name="hero-clipboard-document-list" class="size-12 mx-auto mb-4" />
        <p class="text-lg font-medium">No intents found</p>
        <p class="text-sm mt-1">Intents will appear here once proposed.</p>
      </div>

      <div :if={@filtered_intents != []} class="overflow-x-auto">
        <.table
          id="intents-table"
          rows={@filtered_intents}
          row_id={fn intent -> "intent-#{intent.id}" end}
          row_click={fn intent -> JS.navigate(~p"/intents/#{intent.id}") end}
        >
          <:col :let={intent} label="ID">
            <span class="font-mono text-xs">{truncate_id(intent.id)}</span>
          </:col>
          <:col :let={intent} label="Kind">
            <.intent_kind_badge kind={intent.kind} />
          </:col>
          <:col :let={intent} label="Summary">
            <span class="text-sm">{intent.summary}</span>
          </:col>
          <:col :let={intent} label="State">
            <.intent_state_badge state={intent.state} />
          </:col>
          <:col :let={intent} label="Classification">
            <.classification_badge classification={intent.classification} />
          </:col>
          <:col :let={intent} label="Source">
            <span class="text-xs text-base-content/60">
              {format_source(intent.source)}
            </span>
          </:col>
          <:col :let={intent} label="Updated">
            <.relative_time datetime={intent.updated_at} />
          </:col>
          <:action :let={intent}>
            <.link navigate={~p"/intents/#{intent.id}"} class="link link-primary text-sm">
              View
            </.link>
          </:action>
        </.table>
      </div>
    </div>
    """
  end

  # ── Functional Components ──────────────────────────────────────────

  attr :total, :integer, required: true
  attr :by_state, :map, required: true
  attr :by_kind, :map, required: true

  defp intent_summary_stats(assigns) do
    ~H"""
    <div class="stats shadow w-full">
      <div class="stat">
        <div class="stat-title">Total Intents</div>
        <div class="stat-value">{@total}</div>
      </div>
      <div :for={{state, count} <- sorted_state_counts(@by_state)} class="stat">
        <div class="stat-title">{format_state(state)}</div>
        <div class="stat-value text-lg">
          <.intent_state_badge state={state} />
          <span class="ml-2">{count}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :filter_kind, :string, required: true
  attr :filter_state, :string, required: true
  attr :filter_classification, :string, required: true
  attr :sort_by, :string, required: true

  defp filters(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-3 items-end">
      <div class="form-control">
        <label class="label">
          <span class="label-text text-xs">Kind</span>
        </label>
        <select
          class="select select-bordered select-sm"
          phx-change="filter_kind"
          name="kind"
        >
          <option value="all" selected={@filter_kind == "all"}>All kinds</option>
          <option
            :for={kind <- intent_kinds()}
            value={kind}
            selected={@filter_kind == to_string(kind)}
          >
            {format_kind(kind)}
          </option>
        </select>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text text-xs">State</span>
        </label>
        <select
          class="select select-bordered select-sm"
          phx-change="filter_state"
          name="state"
        >
          <option value="all" selected={@filter_state == "all"}>All states</option>
          <option
            :for={state <- intent_states()}
            value={state}
            selected={@filter_state == to_string(state)}
          >
            {format_state(state)}
          </option>
        </select>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text text-xs">Classification</span>
        </label>
        <select
          class="select select-bordered select-sm"
          phx-change="filter_classification"
          name="classification"
        >
          <option value="all" selected={@filter_classification == "all"}>
            All classifications
          </option>
          <option
            :for={cls <- classifications()}
            value={cls}
            selected={@filter_classification == to_string(cls)}
          >
            {format_classification(cls)}
          </option>
        </select>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text text-xs">Sort</span>
        </label>
        <select
          class="select select-bordered select-sm"
          phx-change="sort"
          name="sort_by"
        >
          <option value="newest" selected={@sort_by == "newest"}>Newest first</option>
          <option value="oldest" selected={@sort_by == "oldest"}>Oldest first</option>
        </select>
      </div>
    </div>
    """
  end

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

  # ── Data Loading & Filtering ──────────────────────────────────────

  defp assign_intents(socket) do
    {:ok, all_intents} = Store.list()

    socket
    |> assign(:all_intents, all_intents)
    |> assign_derived()
  end

  defp assign_derived(socket) do
    all_intents = socket.assigns.all_intents
    filter_kind = socket.assigns.filter_kind
    filter_state = socket.assigns.filter_state
    filter_classification = socket.assigns.filter_classification
    sort_by = socket.assigns.sort_by

    filtered =
      all_intents
      |> filter_by_kind(filter_kind)
      |> filter_by_state(filter_state)
      |> filter_by_classification(filter_classification)
      |> sort_intents(sort_by)

    by_state = Enum.frequencies_by(all_intents, & &1.state)
    by_kind = Enum.frequencies_by(all_intents, & &1.kind)

    socket
    |> assign(:filtered_intents, filtered)
    |> assign(:by_state, by_state)
    |> assign(:by_kind, by_kind)
  end

  defp filter_by_kind(intents, "all"), do: intents

  defp filter_by_kind(intents, kind_str) do
    kind = String.to_existing_atom(kind_str)
    Enum.filter(intents, &(&1.kind == kind))
  end

  defp filter_by_state(intents, "all"), do: intents

  defp filter_by_state(intents, state_str) do
    state = String.to_existing_atom(state_str)
    Enum.filter(intents, &(&1.state == state))
  end

  defp filter_by_classification(intents, "all"), do: intents

  defp filter_by_classification(intents, cls_str) do
    cls = String.to_existing_atom(cls_str)
    Enum.filter(intents, &(&1.classification == cls))
  end

  defp sort_intents(intents, "newest") do
    Enum.sort_by(intents, & &1.updated_at, {:desc, DateTime})
  end

  defp sort_intents(intents, "oldest") do
    Enum.sort_by(intents, & &1.updated_at, {:asc, DateTime})
  end

  defp sort_intents(intents, _), do: intents

  # ── Helpers ────────────────────────────────────────────────────────

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp intent_kinds, do: Intent.valid_kinds()

  defp intent_states, do: Lifecycle.valid_states()

  defp classifications, do: [:safe, :controlled, :dangerous]

  defp truncate_id("int_" <> rest), do: "int_" <> String.slice(rest, 0, 8) <> "..."
  defp truncate_id(id), do: String.slice(id, 0, 16) <> "..."

  defp format_source(%{type: type, id: id}), do: "#{type}:#{id}"
  defp format_source(_), do: "unknown"

  defp format_kind(:action), do: "Action"
  defp format_kind(:inquiry), do: "Inquiry"
  defp format_kind(:maintenance), do: "Maintenance"
  defp format_kind(kind), do: to_string(kind) |> String.capitalize()

  defp format_state(state) do
    state
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_classification(:safe), do: "Safe"
  defp format_classification(:controlled), do: "Controlled"
  defp format_classification(:dangerous), do: "Dangerous"
  defp format_classification(cls), do: to_string(cls) |> String.capitalize()

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

  defp sorted_state_counts(by_state) do
    order = [
      :awaiting_approval,
      :running,
      :approved,
      :proposed,
      :classified,
      :completed,
      :failed,
      :rejected,
      :canceled
    ]

    order
    |> Enum.filter(&Map.has_key?(by_state, &1))
    |> Enum.map(fn state -> {state, Map.get(by_state, state)} end)
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
end
