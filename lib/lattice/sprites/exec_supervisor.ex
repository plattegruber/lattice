defmodule Lattice.Sprites.ExecSupervisor do
  @moduledoc """
  DynamicSupervisor for exec session processes.

  Each WebSocket exec session is a supervised GenServer that manages
  a `:gun` connection to a sprite's exec endpoint.
  """
  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(args) do
    DynamicSupervisor.start_child(__MODULE__, {Lattice.Sprites.ExecSession, args})
  end
end
