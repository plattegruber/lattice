defmodule Lattice.Sprites.ExecSession.Stub do
  @moduledoc """
  Stub GenServer that simulates a WebSocket exec session.

  Used in development and testing to exercise the exec session flow
  without a real WebSocket connection. Broadcasts simulated output
  via PubSub just like the real `ExecSession`.
  """
  use GenServer

  alias Lattice.Sprites.ExecSession

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(args) do
    sprite_id = Keyword.fetch!(args, :sprite_id)
    command = Keyword.fetch!(args, :command)
    idle_timeout = Keyword.get(args, :idle_timeout, 300_000)

    session_id =
      "exec_stub_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    Registry.register(Lattice.Sprites.ExecRegistry, session_id, %{
      sprite_id: sprite_id,
      command: command
    })

    Process.send_after(self(), :simulate_output, 100)

    state = %{
      session_id: session_id,
      sprite_id: sprite_id,
      command: command,
      status: :running,
      started_at: DateTime.utc_now(),
      output_buffer: [],
      buffer_size: 0,
      exit_code: nil,
      idle_timeout: idle_timeout
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    reply = %{
      session_id: state.session_id,
      sprite_id: state.sprite_id,
      command: state.command,
      status: state.status,
      started_at: state.started_at,
      buffer_size: state.buffer_size,
      exit_code: state.exit_code
    }

    {:reply, {:ok, reply}, state}
  end

  def handle_call(:get_output, _from, state) do
    {:reply, {:ok, Enum.reverse(state.output_buffer)}, state}
  end

  def handle_call(:close, _from, state) do
    {:stop, :normal, :ok, %{state | status: :closed}}
  end

  @impl true
  def handle_info(:simulate_output, state) do
    lines = [
      "$ #{state.command}",
      "Executing on #{state.sprite_id}...",
      "Done."
    ]

    new_state =
      Enum.reduce(lines, state, fn line, acc ->
        entry = %{stream: :stdout, data: line, timestamp: DateTime.utc_now()}

        Phoenix.PubSub.broadcast(
          Lattice.PubSub,
          ExecSession.exec_topic(acc.session_id),
          {:exec_output,
           %{
             session_id: acc.session_id,
             sprite_id: acc.sprite_id,
             stream: :stdout,
             chunk: line,
             timestamp: DateTime.utc_now()
           }}
        )

        %{acc | output_buffer: [entry | acc.output_buffer], buffer_size: acc.buffer_size + 1}
      end)

    Process.send_after(self(), :simulate_exit, 50)
    {:noreply, new_state}
  end

  def handle_info(:simulate_exit, state) do
    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      ExecSession.exec_topic(state.session_id),
      {:exec_output,
       %{
         session_id: state.session_id,
         sprite_id: state.sprite_id,
         stream: :exit,
         chunk: "Process exited with code 0",
         timestamp: DateTime.utc_now()
       }}
    )

    {:stop, :normal, %{state | status: :closed, exit_code: 0}}
  end
end
