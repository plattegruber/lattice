defmodule Lattice.Store.ETS do
  @moduledoc """
  ETS-backed implementation of the Store behaviour.

  A GenServer that owns an ETS table for in-memory key-value storage,
  scoped by namespace. The table is `:public` with `:read_concurrency`
  so reads bypass the GenServer for performance.

  ## Design

  - ETS table: `:set`, `:public`, `:named_table`, `read_concurrency: true`
  - Reads go directly to ETS (no GenServer bottleneck)
  - Writes go directly to ETS (`:public` table)
  - The GenServer exists solely to own the table lifetime

  ## Migration Path

  This module implements `Lattice.Store`. When PostgreSQL persistence is
  needed, a new implementation can be swapped in via config:

      config :lattice, :store, Lattice.Store.Postgres
  """

  use GenServer

  @behaviour Lattice.Store

  @table_name :lattice_store

  # ── Behaviour Callbacks (Client API) ─────────────────────────────

  @impl Lattice.Store
  def put(namespace, key, value) when is_atom(namespace) and is_binary(key) and is_map(value) do
    record =
      Map.merge(value, %{
        _key: key,
        _namespace: namespace,
        _updated_at: DateTime.utc_now()
      })

    :ets.insert(@table_name, {{namespace, key}, record})
    :ok
  end

  @impl Lattice.Store
  def get(namespace, key) when is_atom(namespace) and is_binary(key) do
    case :ets.lookup(@table_name, {namespace, key}) do
      [{{^namespace, ^key}, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @impl Lattice.Store
  def list(namespace) when is_atom(namespace) do
    results =
      @table_name
      |> :ets.match_object({{namespace, :_}, :_})
      |> Enum.map(fn {_key, value} -> value end)

    {:ok, results}
  end

  @impl Lattice.Store
  def delete(namespace, key) when is_atom(namespace) and is_binary(key) do
    :ets.delete(@table_name, {namespace, key})
    :ok
  end

  # ── GenServer (Table Owner) ──────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
