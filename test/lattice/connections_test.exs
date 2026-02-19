defmodule Lattice.ConnectionsTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Connections

  setup do
    # Clear any existing connection
    table = :lattice_connections

    try do
      :ets.delete_all_objects(table)
    rescue
      ArgumentError -> :ok
    end

    # Preserve original resources config
    prev = Application.get_env(:lattice, :resources, [])
    on_exit(fn -> Application.put_env(:lattice, :resources, prev) end)

    :ok
  end

  describe "current_repo/0" do
    test "returns nil when no repo is connected" do
      assert Connections.current_repo() == nil
    end

    test "returns the connection after connecting" do
      {:ok, _} = Connections.connect_repo("owner/repo", "user_123")
      connection = Connections.current_repo()
      assert connection.repo == "owner/repo"
      assert connection.connected_by == "user_123"
      assert %DateTime{} = connection.connected_at
    end
  end

  describe "connect_repo/2" do
    test "stores the connection and updates runtime config" do
      {:ok, connection} = Connections.connect_repo("acme/widgets", "user_456")
      assert connection.repo == "acme/widgets"
      assert connection.connected_by == "user_456"

      # Runtime config should be updated
      assert Application.get_env(:lattice, :resources)[:github_repo] == "acme/widgets"
    end

    test "overwrites previous connection" do
      {:ok, _} = Connections.connect_repo("acme/old", "user_1")
      {:ok, _} = Connections.connect_repo("acme/new", "user_2")

      connection = Connections.current_repo()
      assert connection.repo == "acme/new"
      assert connection.connected_by == "user_2"
    end
  end

  describe "disconnect_repo/0" do
    test "clears the connection and runtime config" do
      {:ok, _} = Connections.connect_repo("acme/widgets", "user_123")
      assert Connections.current_repo() != nil

      :ok = Connections.disconnect_repo()

      assert Connections.current_repo() == nil
      assert Application.get_env(:lattice, :resources)[:github_repo] == nil
    end

    test "is a no-op when nothing is connected" do
      assert :ok = Connections.disconnect_repo()
    end
  end
end
