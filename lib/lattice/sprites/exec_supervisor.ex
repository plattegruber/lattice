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

  @doc """
  List all active exec sessions.

  Returns a list of `{session_id, pid, metadata}` tuples from the ExecRegistry.
  """
  @spec list_sessions() :: [{String.t(), pid(), map()}]
  def list_sessions do
    Registry.select(Lattice.Sprites.ExecRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  @doc """
  List active exec sessions for a specific sprite.

  Returns a list of `{session_id, pid, metadata}` tuples filtered by sprite_id.
  """
  @spec list_sessions_for_sprite(String.t()) :: [{String.t(), pid(), map()}]
  def list_sessions_for_sprite(sprite_id) do
    list_sessions()
    |> Enum.filter(fn {_session_id, _pid, meta} -> meta.sprite_id == sprite_id end)
  end

  @doc """
  Look up a session process by session ID in the ExecRegistry.

  Returns `{:ok, pid}` if found, or `{:error, :not_found}`.
  """
  @spec get_session_pid(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def get_session_pid(session_id) do
    case Registry.lookup(Lattice.Sprites.ExecRegistry, session_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
