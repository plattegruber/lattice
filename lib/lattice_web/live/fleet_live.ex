defmodule LatticeWeb.FleetLive do
  use LatticeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Fleet")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold text-gray-100">Fleet Overview</h1>
        <span class="inline-flex items-center gap-1.5 rounded-full bg-emerald-900/50 px-3 py-1 text-sm text-emerald-400">
          <span class="h-2 w-2 rounded-full bg-emerald-400"></span>
          Operational
        </span>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div class="rounded-lg border border-gray-800 bg-gray-900 p-6">
          <p class="text-sm text-gray-400">Active Sprites</p>
          <p class="mt-2 text-3xl font-bold text-gray-100">0</p>
        </div>
        <div class="rounded-lg border border-gray-800 bg-gray-900 p-6">
          <p class="text-sm text-gray-400">Pending Approvals</p>
          <p class="mt-2 text-3xl font-bold text-gray-100">0</p>
        </div>
        <div class="rounded-lg border border-gray-800 bg-gray-900 p-6">
          <p class="text-sm text-gray-400">Incidents</p>
          <p class="mt-2 text-3xl font-bold text-gray-100">0</p>
        </div>
      </div>

      <div class="rounded-lg border border-gray-800 bg-gray-900 p-6">
        <h2 class="text-lg font-semibold text-gray-200">Sprites</h2>
        <p class="mt-4 text-sm text-gray-500">
          No sprites running. The fleet is idle.
        </p>
      </div>
    </div>
    """
  end
end
