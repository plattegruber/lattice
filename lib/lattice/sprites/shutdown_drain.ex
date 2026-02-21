defmodule Lattice.Sprites.ShutdownDrain do
  @moduledoc """
  Graceful SIGTERM drain for active exec sessions.

  Fly.io sends SIGTERM when autostop decides to reclaim a machine. Without
  intervention the BEAM shuts down immediately, killing any in-flight exec
  sessions (and the Claude processes running inside sprites).

  This GenServer traps SIGTERM, checks for active exec sessions, and delays
  the application shutdown until all sessions finish (or the drain timeout
  expires). The fly.toml `kill_timeout` value must be set high enough to
  cover the maximum expected drain window.

  Drain timeout (default 10 minutes) is configurable via application env:

      config :lattice, Lattice.Sprites.ShutdownDrain, drain_timeout_ms: 600_000
  """
  use GenServer

  require Logger

  @default_drain_timeout_ms 600_000
  @poll_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{draining: false}}
  end

  @impl true
  def handle_info({:signal, :sigterm}, state) do
    sessions = Lattice.Sprites.ExecSupervisor.list_sessions()

    if sessions == [] do
      Logger.info("ShutdownDrain: no active exec sessions — shutting down immediately")
      System.stop(0)
      {:noreply, state}
    else
      Logger.warning(
        "ShutdownDrain: SIGTERM received with #{length(sessions)} active exec session(s) — draining"
      )

      drain_timeout = drain_timeout_ms()
      Process.send_after(self(), :drain_timeout, drain_timeout)
      send(self(), :poll_sessions)
      {:noreply, %{state | draining: true}}
    end
  end

  def handle_info(:poll_sessions, %{draining: true} = state) do
    sessions = Lattice.Sprites.ExecSupervisor.list_sessions()

    if sessions == [] do
      Logger.info("ShutdownDrain: all exec sessions finished — shutting down")
      System.stop(0)
      {:noreply, state}
    else
      Logger.info(
        "ShutdownDrain: waiting on #{length(sessions)} exec session(s): " <>
          inspect(Enum.map(sessions, fn {id, _pid, _meta} -> id end))
      )

      Process.send_after(self(), :poll_sessions, @poll_interval_ms)
      {:noreply, state}
    end
  end

  def handle_info(:drain_timeout, %{draining: true} = state) do
    sessions = Lattice.Sprites.ExecSupervisor.list_sessions()

    Logger.error(
      "ShutdownDrain: drain timeout reached with #{length(sessions)} session(s) still active — forcing shutdown"
    )

    System.stop(0)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp drain_timeout_ms do
    config = Application.get_env(:lattice, __MODULE__, [])
    Keyword.get(config, :drain_timeout_ms, @default_drain_timeout_ms)
  end
end
