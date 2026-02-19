defmodule LatticeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use LatticeWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_operator, :map, default: nil, doc: "the authenticated operator"

  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assign_new(assigns, :connected_repo, fn -> Lattice.Instance.resource(:github_repo) end)

    ~H"""
    <header class="navbar bg-base-200 px-4 sm:px-6 lg:px-8 border-b border-base-300">
      <div class="flex-1">
        <.link navigate={~p"/sprites"} class="flex items-center gap-2 font-bold text-lg">
          <.icon name="hero-cube-transparent" class="size-6" /> Lattice
          <span class="badge badge-xs badge-ghost font-normal text-[10px]">control plane</span>
        </.link>
        <%= if @connected_repo do %>
          <.link
            navigate={~p"/settings/repository"}
            class="ml-3 badge badge-sm badge-outline gap-1 opacity-70 hover:opacity-100"
          >
            <.icon name="hero-link" class="size-3" />
            {@connected_repo}
          </.link>
        <% end %>
      </div>
      <div class="flex-none">
        <ul class="menu menu-horizontal px-1 space-x-1 items-center">
          <li>
            <.link navigate={~p"/sprites"} class="font-medium">
              <span class="relative">
                <.icon name="hero-squares-2x2" class="size-4" />
                <span class="absolute -top-0.5 -right-0.5 size-1.5 rounded-full bg-success" />
              </span>
              Fleet
            </.link>
          </li>
          <li>
            <.link navigate={~p"/approvals"} class="font-medium">
              <span class="relative">
                <.icon name="hero-shield-check" class="size-4" />
                <span class="absolute -top-0.5 -right-0.5 size-1.5 rounded-full bg-success" />
              </span>
              Approvals
            </.link>
          </li>
          <li>
            <.link navigate={~p"/intents"} class="font-medium">
              <span class="relative">
                <.icon name="hero-clipboard-document-list" class="size-4" />
                <span class="absolute -top-0.5 -right-0.5 size-1.5 rounded-full bg-success" />
              </span>
              Intents
            </.link>
          </li>
          <li>
            <.link navigate={~p"/incidents"} class="font-medium">
              <span class="relative">
                <.icon name="hero-exclamation-triangle" class="size-4" />
                <span class="absolute -top-0.5 -right-0.5 size-1.5 rounded-full bg-success" />
              </span>
              Incidents
            </.link>
          </li>
          <li>
            <.link navigate={~p"/audit"} class="font-medium">
              <span class="relative">
                <.icon name="hero-document-magnifying-glass" class="size-4" />
                <span class="absolute -top-0.5 -right-0.5 size-1.5 rounded-full bg-success" />
              </span>
              Audit
            </.link>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <%= if @current_operator do %>
            <li>
              <details class="dropdown dropdown-end">
                <summary class="font-medium">
                  <.icon name="hero-user-circle" class="size-5" />
                  <span class="hidden sm:inline">{@current_operator.name}</span>
                </summary>
                <ul class="dropdown-content menu bg-base-200 rounded-box z-50 w-52 p-2 shadow-lg border border-base-300">
                  <li class="menu-title text-xs opacity-60">
                    {@current_operator.name}
                    <span class="badge badge-xs badge-ghost ml-1">{@current_operator.role}</span>
                  </li>
                  <li>
                    <.link navigate={~p"/settings/repository"}>
                      <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
                    </.link>
                  </li>
                  <li>
                    <.link href={~p"/auth/logout"} method="get">
                      <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Sign out
                    </.link>
                  </li>
                </ul>
              </details>
            </li>
          <% end %>
        </ul>
      </div>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-5xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
