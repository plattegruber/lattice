defmodule LatticeWeb.SpritePlaceholderLive do
  @moduledoc """
  Placeholder LiveView for the Sprite detail page.

  Will be replaced with a full Sprite detail view in a future issue.
  """

  use LatticeWeb, :live_view

  @impl true
  def mount(%{"id" => sprite_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sprite #{sprite_id}")
     |> assign(:sprite_id, sprite_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Sprite: {@sprite_id}
        <:subtitle>
          Detail view coming soon.
        </:subtitle>
      </.header>

      <div class="text-center py-12 text-base-content/60">
        <.icon name="hero-wrench-screwdriver" class="size-12 mx-auto mb-4" />
        <p class="text-lg font-medium">Under construction</p>
        <p class="text-sm mt-1">
          The sprite detail view will be implemented in a future issue.
        </p>
      </div>

      <div class="text-center">
        <.link navigate={~p"/sprites"} class="btn btn-ghost">
          <.icon name="hero-arrow-left" class="size-4 mr-1" /> Back to Fleet
        </.link>
      </div>
    </div>
    """
  end
end
