defmodule Lattice.Store.ETSTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Store

  # The ETS store is started by the application supervision tree,
  # so the table already exists during tests.

  setup do
    # Clean up any test data before each test
    {:ok, entries} = Store.list(:test_ns)

    Enum.each(entries, fn entry ->
      Store.delete(:test_ns, entry._key)
    end)

    :ok
  end

  describe "put/3 and get/3" do
    test "stores and retrieves a value" do
      assert :ok = Store.put(:test_ns, "key-1", %{name: "alpha"})
      assert {:ok, value} = Store.get(:test_ns, "key-1")
      assert value.name == "alpha"
      assert value._key == "key-1"
      assert value._namespace == :test_ns
      assert %DateTime{} = value._updated_at
    end

    test "overwrites existing values" do
      :ok = Store.put(:test_ns, "key-2", %{version: 1})
      :ok = Store.put(:test_ns, "key-2", %{version: 2})

      {:ok, value} = Store.get(:test_ns, "key-2")
      assert value.version == 2
    end

    test "merges metadata keys into the stored value" do
      :ok = Store.put(:test_ns, "key-3", %{color: "blue"})
      {:ok, value} = Store.get(:test_ns, "key-3")

      assert value.color == "blue"
      assert value._key == "key-3"
      assert value._namespace == :test_ns
    end
  end

  describe "get/3" do
    test "returns {:error, :not_found} for nonexistent key" do
      assert {:error, :not_found} = Store.get(:test_ns, "nonexistent")
    end

    test "namespaces are isolated" do
      :ok = Store.put(:ns_a, "shared-key", %{from: "a"})

      assert {:error, :not_found} = Store.get(:ns_b, "shared-key")
      assert {:ok, value} = Store.get(:ns_a, "shared-key")
      assert value.from == "a"

      # Clean up
      Store.delete(:ns_a, "shared-key")
    end
  end

  describe "list/1" do
    test "returns {:ok, []} for empty namespace" do
      assert {:ok, []} = Store.list(:empty_ns)
    end

    test "returns all values in a namespace" do
      :ok = Store.put(:test_ns, "list-1", %{name: "first"})
      :ok = Store.put(:test_ns, "list-2", %{name: "second"})

      {:ok, results} = Store.list(:test_ns)
      assert length(results) == 2

      names = Enum.map(results, & &1.name) |> Enum.sort()
      assert names == ["first", "second"]
    end

    test "does not include values from other namespaces" do
      :ok = Store.put(:test_ns, "scoped-1", %{name: "in scope"})
      :ok = Store.put(:other_ns, "scoped-2", %{name: "out of scope"})

      {:ok, results} = Store.list(:test_ns)
      names = Enum.map(results, & &1.name)
      assert "in scope" in names
      refute "out of scope" in names

      # Clean up
      Store.delete(:other_ns, "scoped-2")
    end
  end

  describe "delete/2" do
    test "removes an existing entry" do
      :ok = Store.put(:test_ns, "del-1", %{name: "doomed"})
      assert {:ok, _} = Store.get(:test_ns, "del-1")

      assert :ok = Store.delete(:test_ns, "del-1")
      assert {:error, :not_found} = Store.get(:test_ns, "del-1")
    end

    test "returns :ok for nonexistent key" do
      assert :ok = Store.delete(:test_ns, "never-existed")
    end
  end
end
