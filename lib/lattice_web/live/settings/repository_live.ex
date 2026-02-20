defmodule LatticeWeb.Settings.RepositoryLive do
  @moduledoc """
  Settings page for connecting and disconnecting a GitHub repository.

  Shows the current connection status and a repo picker that lists
  repos accessible to the operator via their GitHub OAuth token.
  """

  use LatticeWeb, :live_view

  alias Lattice.Auth.ClerkGitHub
  alias Lattice.Connections
  alias Lattice.Connections.GitHubRepos
  alias Lattice.Connections.WebhookSetup

  @impl true
  def mount(_params, session, socket) do
    operator_id = Map.get(session, "operator_id")
    connection = Connections.current_repo()

    socket =
      socket
      |> assign(:connection, connection)
      |> assign(:operator_id, operator_id)
      |> assign(:repos, [])
      |> assign(:loading_repos, false)
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Repository Settings
        <:subtitle>
          Connect a GitHub repository so Lattice can manage issues, PRs, and webhooks.
        </:subtitle>
      </.header>

      <%= if @error do %>
        <div class="alert alert-error">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>{@error}</span>
        </div>
      <% end %>

      <div class="card bg-base-200 p-6 space-y-4">
        <h3 class="font-semibold text-lg">Current Connection</h3>

        <%= if @connection do %>
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <span class="badge badge-success badge-sm">Connected</span>
              <span class="font-mono font-medium">{@connection.repo}</span>
              <span class="text-xs opacity-60">
                by {@connection.connected_by} on {Calendar.strftime(
                  @connection.connected_at,
                  "%Y-%m-%d %H:%M UTC"
                )}
              </span>
            </div>
            <button
              phx-click="disconnect"
              class="btn btn-error btn-sm btn-outline"
              data-confirm="Disconnect this repo? This will remove the webhook."
            >
              <.icon name="hero-x-mark" class="size-4" /> Disconnect
            </button>
          </div>
        <% else %>
          <div class="flex items-center gap-2 opacity-60">
            <span class="badge badge-ghost badge-sm">Not connected</span>
            <span class="text-sm">No repository is currently connected.</span>
          </div>
        <% end %>
      </div>

      <div class="card bg-base-200 p-6 space-y-4">
        <div class="flex items-center justify-between">
          <h3 class="font-semibold text-lg">Connect a Repository</h3>
          <button
            phx-click="load_repos"
            class={"btn btn-sm btn-primary btn-outline #{if @loading_repos, do: "loading"}"}
            disabled={@loading_repos}
          >
            <.icon name="hero-arrow-path" class="size-4" />
            {if @loading_repos, do: "Loading...", else: "Load Repos"}
          </button>
        </div>

        <%= if @repos != [] do %>
          <div class="overflow-x-auto max-h-96">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Repository</th>
                  <th>Visibility</th>
                  <th>Description</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for repo <- @repos do %>
                  <tr class="hover">
                    <td class="font-mono font-medium">{repo.full_name}</td>
                    <td>
                      <span class={"badge badge-xs #{if repo.private, do: "badge-warning", else: "badge-info"}"}>
                        {if repo.private, do: "private", else: "public"}
                      </span>
                    </td>
                    <td class="text-sm opacity-70 max-w-xs truncate">{repo.description || ""}</td>
                    <td>
                      <button
                        phx-click="connect"
                        phx-value-repo={repo.full_name}
                        class="btn btn-xs btn-primary"
                        disabled={@connection && @connection.repo == repo.full_name}
                      >
                        {if @connection && @connection.repo == repo.full_name,
                          do: "Connected",
                          else: "Connect"}
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("load_repos", _params, socket) do
    socket = assign(socket, :loading_repos, true)
    send(self(), :fetch_repos)
    {:noreply, socket}
  end

  def handle_event("connect", %{"repo" => repo}, socket) do
    operator_id = socket.assigns.operator_id || "unknown"

    case Connections.connect_repo(repo, operator_id) do
      {:ok, connection} ->
        # Try to set up the webhook (best-effort)
        setup_webhook(repo, socket.assigns.operator_id)

        {:noreply,
         socket
         |> assign(:connection, connection)
         |> assign(:error, nil)
         |> put_flash(:info, "Connected to #{repo}")}
    end
  end

  def handle_event("disconnect", _params, socket) do
    case socket.assigns.connection do
      %{repo: repo} ->
        # Try to remove the webhook (best-effort)
        teardown_webhook(repo, socket.assigns.operator_id)

        Connections.disconnect_repo()

        {:noreply,
         socket
         |> assign(:connection, nil)
         |> assign(:error, nil)
         |> put_flash(:info, "Disconnected from #{repo}")}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:fetch_repos, socket) do
    operator_id = socket.assigns.operator_id

    result =
      if operator_id do
        case ClerkGitHub.fetch_token(operator_id) do
          {:ok, token} -> GitHubRepos.list(token)
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :no_operator}
      end

    socket =
      case result do
        {:ok, repos} ->
          socket
          |> assign(:repos, repos)
          |> assign(:loading_repos, false)
          |> assign(:error, nil)

        {:error, reason} ->
          socket
          |> assign(:loading_repos, false)
          |> assign(:error, "Failed to load repositories: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  defp setup_webhook(repo, operator_id) do
    if operator_id do
      case ClerkGitHub.fetch_token(operator_id) do
        {:ok, token} ->
          host = LatticeWeb.Endpoint.url()
          WebhookSetup.create(repo, token, host)

        _ ->
          :ok
      end
    end
  end

  defp teardown_webhook(repo, operator_id) do
    if operator_id do
      case ClerkGitHub.fetch_token(operator_id) do
        {:ok, token} -> WebhookSetup.delete(repo, token)
        _ -> :ok
      end
    end
  end
end
