defmodule Lattice.Connections do
  @moduledoc """
  Context module for managing repository connections.

  Stores the active GitHub repo connection in ETS and updates the runtime
  config so capabilities use the connected repo. Only one repo can be
  connected at a time.

  ## Data Shape

      %{
        repo: "owner/repo",
        connected_by: "clerk_user_id",
        connected_at: ~U[2026-01-01 00:00:00Z]
      }
  """

  require Logger

  @ets_table :lattice_connections

  @doc """
  Returns the current repo connection, or nil if none is active.
  """
  @spec current_repo() :: map() | nil
  def current_repo do
    ensure_ets_table()

    case :ets.lookup(@ets_table, :github_repo) do
      [{:github_repo, connection}] -> connection
      [] -> nil
    end
  end

  @doc """
  Connect a GitHub repository.

  Updates the runtime configuration so all capabilities use this repo.
  Returns `{:ok, connection}` on success.
  """
  @spec connect_repo(String.t(), String.t()) :: {:ok, map()}
  def connect_repo(repo, connected_by) when is_binary(repo) and is_binary(connected_by) do
    connection = %{
      repo: repo,
      connected_by: connected_by,
      connected_at: DateTime.utc_now()
    }

    ensure_ets_table()
    :ets.insert(@ets_table, {:github_repo, connection})

    # Update runtime config so capabilities see the new repo
    resources = Application.get_env(:lattice, :resources, [])
    Application.put_env(:lattice, :resources, Keyword.put(resources, :github_repo, repo))

    Logger.info("Connected GitHub repo #{repo} by #{connected_by}")
    {:ok, connection}
  end

  @doc """
  Disconnect the current GitHub repository.

  Clears the runtime configuration. Returns `:ok`.
  """
  @spec disconnect_repo() :: :ok
  def disconnect_repo do
    ensure_ets_table()

    case :ets.lookup(@ets_table, :github_repo) do
      [{:github_repo, %{repo: repo}}] ->
        :ets.delete(@ets_table, :github_repo)

        resources = Application.get_env(:lattice, :resources, [])
        Application.put_env(:lattice, :resources, Keyword.put(resources, :github_repo, nil))

        Logger.info("Disconnected GitHub repo #{repo}")

      [] ->
        :ok
    end

    :ok
  end

  defp ensure_ets_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:set, :public, :named_table])

      _ ->
        :ok
    end
  end
end
