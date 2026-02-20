defmodule LatticeWeb.AuditLive do
  @moduledoc """
  Audit log LiveView — real-time view of capability invocations.

  Displays audit entries as they arrive via PubSub, with filtering by
  capability, classification, and result. Entries are accumulated in
  LiveView assigns (not persisted).

  Also shows capability call metrics from telemetry.
  """

  use LatticeWeb, :live_view

  alias Lattice.Events
  alias Lattice.Safety.AuditEntry

  @max_entries 200
  @refresh_interval_ms 30_000

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_audit()
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Audit Log")
     |> assign(:entries, [])
     |> assign(:filter_capability, nil)
     |> assign(:filter_classification, nil)
     |> assign(:filter_result, nil)
     |> assign(:entry_count, 0)
     |> assign(:capabilities_seen, MapSet.new())}
  end

  # ── Event Handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info(%AuditEntry{} = entry, socket) do
    entries = [entry | socket.assigns.entries] |> Enum.take(@max_entries)
    capabilities_seen = MapSet.put(socket.assigns.capabilities_seen, entry.capability)

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> assign(:entry_count, length(entries))
     |> assign(:capabilities_seen, capabilities_seen)}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:filter_capability, parse_filter(params["capability"]))
     |> assign(:filter_classification, parse_filter(params["classification"]))
     |> assign(:filter_result, parse_filter(params["result"]))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filter_capability, nil)
     |> assign(:filter_classification, nil)
     |> assign(:filter_result, nil)}
  end

  # ── Rendering ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    filtered = filter_entries(assigns)

    assigns = assign(assigns, :filtered_entries, filtered)

    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Audit Log</h1>
        <div class="badge badge-info">{@entry_count} entries</div>
      </div>
      
    <!-- Filters -->
      <form phx-change="filter" class="flex gap-4 items-end">
        <div class="form-control">
          <label class="label"><span class="label-text">Capability</span></label>
          <select name="capability" class="select select-bordered select-sm">
            <option value="">All</option>
            <%= for cap <- Enum.sort(MapSet.to_list(@capabilities_seen)) do %>
              <option value={cap} selected={@filter_capability == cap}>{cap}</option>
            <% end %>
          </select>
        </div>
        <div class="form-control">
          <label class="label"><span class="label-text">Classification</span></label>
          <select name="classification" class="select select-bordered select-sm">
            <option value="">All</option>
            <option value="safe" selected={@filter_classification == :safe}>Safe</option>
            <option value="controlled" selected={@filter_classification == :controlled}>
              Controlled
            </option>
            <option value="dangerous" selected={@filter_classification == :dangerous}>
              Dangerous
            </option>
          </select>
        </div>
        <div class="form-control">
          <label class="label"><span class="label-text">Result</span></label>
          <select name="result" class="select select-bordered select-sm">
            <option value="">All</option>
            <option value="ok" selected={@filter_result == :ok}>OK</option>
            <option value="error" selected={@filter_result == :error}>Error</option>
            <option value="denied" selected={@filter_result == :denied}>Denied</option>
          </select>
        </div>
        <button type="button" phx-click="clear_filters" class="btn btn-ghost btn-sm">
          Clear
        </button>
      </form>
      
    <!-- Entries Table -->
      <div class="overflow-x-auto">
        <table class="table table-compact w-full">
          <thead>
            <tr>
              <th>Time</th>
              <th>Capability</th>
              <th>Operation</th>
              <th>Classification</th>
              <th>Result</th>
              <th>Actor</th>
              <th>Args</th>
            </tr>
          </thead>
          <tbody>
            <%= for entry <- @filtered_entries do %>
              <tr class={result_row_class(entry.result)}>
                <td class="font-mono text-xs">{format_time(entry.timestamp)}</td>
                <td>{entry.capability}</td>
                <td>{entry.operation}</td>
                <td>
                  <span class={classification_badge(entry.classification)}>
                    {entry.classification}
                  </span>
                </td>
                <td>{format_result(entry.result)}</td>
                <td>{entry.actor}</td>
                <td class="font-mono text-xs max-w-xs truncate">
                  {format_args(entry.args)}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%= if @filtered_entries == [] do %>
        <div class="text-center py-12 text-base-content/50">
          <p class="text-lg">No audit entries yet</p>
          <p class="text-sm">Entries appear as capability calls are made</p>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Private ────────────────────────────────────────────────────────

  defp filter_entries(assigns) do
    assigns.entries
    |> maybe_filter_by(:capability, assigns.filter_capability)
    |> maybe_filter_by(:classification, assigns.filter_classification)
    |> maybe_filter_result(assigns.filter_result)
  end

  defp maybe_filter_by(entries, _field, nil), do: entries

  defp maybe_filter_by(entries, field, value) do
    Enum.filter(entries, &(Map.get(&1, field) == value))
  end

  defp maybe_filter_result(entries, nil), do: entries
  defp maybe_filter_result(entries, :ok), do: Enum.filter(entries, &(&1.result == :ok))
  defp maybe_filter_result(entries, :denied), do: Enum.filter(entries, &(&1.result == :denied))

  defp maybe_filter_result(entries, :error) do
    Enum.filter(entries, fn e ->
      match?({:error, _}, e.result)
    end)
  end

  defp parse_filter(""), do: nil
  defp parse_filter(nil), do: nil

  defp parse_filter(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp format_time(nil), do: "-"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp format_result(:ok), do: "OK"
  defp format_result(:denied), do: "DENIED"
  defp format_result({:error, reason}), do: "ERROR: #{inspect(reason)}"
  defp format_result(other), do: inspect(other)

  defp format_args([]), do: "-"
  defp format_args(args), do: Enum.map_join(args, ", ", &inspect/1)

  defp classification_badge(:safe), do: "badge badge-success badge-sm"
  defp classification_badge(:controlled), do: "badge badge-warning badge-sm"
  defp classification_badge(:dangerous), do: "badge badge-error badge-sm"
  defp classification_badge(_), do: "badge badge-ghost badge-sm"

  defp result_row_class(:ok), do: ""
  defp result_row_class(:denied), do: "bg-warning/10"
  defp result_row_class({:error, _}), do: "bg-error/10"
  defp result_row_class(_), do: ""

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end
end
