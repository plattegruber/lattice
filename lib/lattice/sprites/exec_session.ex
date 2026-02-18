defmodule Lattice.Sprites.ExecSession do
  @moduledoc """
  GenServer managing an exec session with a sprite via `Sprites.Command`.

  Uses the sprites-ex SDK to connect and stream command output.
  Broadcasts output chunks via PubSub and maintains an output buffer for replay.
  """
  use GenServer

  require Logger

  alias Lattice.Events
  alias Lattice.Protocol.Event
  alias Lattice.Protocol.Parser
  alias Lattice.Sprites.Logs

  @default_idle_timeout 300_000
  @max_buffer_lines 1000

  defstruct [
    :session_id,
    :sprite_id,
    :command,
    :sprites_command,
    :status,
    :started_at,
    :idle_timer,
    idle_timeout: @default_idle_timeout,
    output_buffer: [],
    buffer_size: 0,
    exit_code: nil,
    events: []
  ]

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  def get_output(pid) do
    GenServer.call(pid, :get_output)
  end

  def close(pid) do
    GenServer.call(pid, :close)
  end

  def get_events(pid) do
    GenServer.call(pid, :get_events)
  end

  @doc "Returns the PubSub topic for a given session ID."
  def exec_topic(session_id), do: "exec:#{session_id}"

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(args) do
    case sprites_api_token_safe() do
      nil ->
        {:stop, :missing_sprites_api_token}

      _token ->
        do_init(args)
    end
  end

  defp do_init(args) do
    session_id = generate_session_id()
    sprite_id = Keyword.fetch!(args, :sprite_id)
    command = Keyword.fetch!(args, :command)
    idle_timeout = Keyword.get(args, :idle_timeout, @default_idle_timeout)

    {:ok, _} =
      Registry.register(Lattice.Sprites.ExecRegistry, session_id, %{
        sprite_id: sprite_id,
        command: command
      })

    state = %__MODULE__{
      session_id: session_id,
      sprite_id: sprite_id,
      command: command,
      status: :connecting,
      started_at: DateTime.utc_now(),
      idle_timeout: idle_timeout
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case start_command(state.sprite_id, state.command) do
      {:ok, cmd} ->
        Process.link(cmd.pid)

        new_state = %{
          state
          | sprites_command: cmd,
            status: :running,
            idle_timer: schedule_idle_timeout(state.idle_timeout)
        }

        Logger.info("Exec session #{state.session_id} connected to sprite #{state.sprite_id}")

        :telemetry.execute(
          [:lattice, :exec, :started],
          %{count: 1},
          %{session_id: state.session_id, sprite_id: state.sprite_id, command: state.command}
        )

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Exec session #{state.session_id} failed to connect: #{inspect(reason)}")

        :telemetry.execute(
          [:lattice, :exec, :failed],
          %{count: 1},
          %{session_id: state.session_id, sprite_id: state.sprite_id, reason: reason}
        )

        {:stop, {:shutdown, {:connection_failed, reason}}, state}
    end
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
      exit_code: state.exit_code,
      event_count: length(state.events)
    }

    {:reply, {:ok, reply}, state}
  end

  def handle_call(:get_output, _from, state) do
    {:reply, {:ok, Enum.reverse(state.output_buffer)}, state}
  end

  def handle_call(:get_events, _from, state) do
    {:reply, {:ok, Enum.reverse(state.events)}, state}
  end

  def handle_call(:close, _from, state) do
    new_state = do_close(state)
    {:stop, :normal, :ok, new_state}
  end

  # ── Sprites.Command message handlers ─────────────────────────────────

  @impl true
  def handle_info({:stdout, %{ref: ref}, data}, %{sprites_command: %{ref: ref}} = state) do
    state = cancel_idle_timer(state)
    new_state = handle_output_chunk(state, :stdout, data)
    {:noreply, reset_idle_timer(new_state)}
  end

  def handle_info({:stderr, %{ref: ref}, data}, %{sprites_command: %{ref: ref}} = state) do
    state = cancel_idle_timer(state)
    new_state = handle_output_chunk(state, :stderr, data)
    {:noreply, reset_idle_timer(new_state)}
  end

  def handle_info({:exit, %{ref: ref}, code}, %{sprites_command: %{ref: ref}} = state) do
    new_state = %{state | exit_code: code, status: :closed}

    :telemetry.execute(
      [:lattice, :exec, :completed],
      %{count: 1, exit_code: code},
      %{session_id: state.session_id, sprite_id: state.sprite_id}
    )

    broadcast_output(new_state, :exit, "Process exited with code #{code}")
    {:stop, :normal, new_state}
  end

  def handle_info({:error, %{ref: ref}, reason}, %{sprites_command: %{ref: ref}} = state) do
    Logger.error("Exec session #{state.session_id} command error: #{inspect(reason)}")
    broadcast_output(state, :stderr, "Error: #{inspect(reason)}")
    {:stop, {:shutdown, reason}, %{state | status: :closed}}
  end

  # Idle timeout
  def handle_info(:idle_timeout, state) do
    Logger.info("Exec session #{state.session_id} idle timeout after #{state.idle_timeout}ms")
    new_state = do_close(state)
    {:stop, :normal, new_state}
  end

  # Catch-all
  def handle_info(msg, state) do
    Logger.debug("Exec session #{state.session_id} unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if cmd = state.sprites_command do
      if Process.alive?(cmd.pid) do
        Process.unlink(cmd.pid)
        GenServer.stop(cmd.pid, :normal, 5_000)
      end
    end

    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp start_command(sprite_id, command) do
    token = sprites_api_token()
    base_url = sprites_api_base()

    client = Sprites.new(token, base_url: base_url)
    sprite = Sprites.sprite(client, sprite_id)

    Sprites.spawn(sprite, "sh", ["-c", command], owner: self())
  end

  defp handle_output_chunk(state, stream, chunk) do
    broadcast_output(state, stream, chunk)
    state = add_to_buffer(state, stream, chunk)

    # Parse lines for LATTICE_EVENT protocol events
    if stream == :stdout do
      parse_and_broadcast_events(state, chunk)
    else
      state
    end
  end

  defp parse_and_broadcast_events(state, chunk) do
    lines = String.split(to_string(chunk), "\n", trim: true)

    Enum.reduce(lines, state, fn line, acc ->
      case Parser.parse_line(line) do
        {:event, event} ->
          broadcast_event(acc, event)
          add_event_to_buffer(acc, event)

        {:text, _} ->
          acc
      end
    end)
  end

  defp broadcast_event(state, %Event{} = event) do
    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      "exec:#{state.session_id}:events",
      {:protocol_event, event}
    )

    :telemetry.execute(
      [:lattice, :protocol, :event_received],
      %{count: 1},
      %{session_id: state.session_id, sprite_id: state.sprite_id, event_type: event.type}
    )
  end

  defp add_event_to_buffer(state, event) do
    %{state | events: [event | state.events]}
  end

  defp broadcast_output(state, stream, chunk) do
    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      exec_topic(state.session_id),
      {:exec_output,
       %{
         session_id: state.session_id,
         sprite_id: state.sprite_id,
         stream: stream,
         chunk: chunk,
         timestamp: DateTime.utc_now()
       }}
    )

    # Also broadcast to unified sprite logs topic
    log_line =
      Logs.from_exec_output(%{
        session_id: state.session_id,
        stream: stream,
        chunk: chunk
      })

    Events.broadcast_sprite_log(state.sprite_id, log_line)

    :telemetry.execute(
      [:lattice, :exec, :output],
      %{bytes: byte_size(to_string(chunk))},
      %{session_id: state.session_id, sprite_id: state.sprite_id, stream: stream}
    )
  end

  defp add_to_buffer(state, stream, chunk) do
    entry = %{stream: stream, data: chunk, timestamp: DateTime.utc_now()}

    new_buffer =
      if state.buffer_size >= @max_buffer_lines do
        [entry | Enum.take(state.output_buffer, @max_buffer_lines - 1)]
      else
        [entry | state.output_buffer]
      end

    %{
      state
      | output_buffer: new_buffer,
        buffer_size: min(state.buffer_size + 1, @max_buffer_lines)
    }
  end

  defp schedule_idle_timeout(timeout) do
    Process.send_after(self(), :idle_timeout, timeout)
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  defp reset_idle_timer(state) do
    %{state | idle_timer: schedule_idle_timeout(state.idle_timeout)}
  end

  defp do_close(state) do
    if cmd = state.sprites_command do
      if Process.alive?(cmd.pid) do
        Process.unlink(cmd.pid)
        GenServer.stop(cmd.pid, :normal, 5_000)
      end
    end

    state = cancel_idle_timer(state)
    %{state | status: :closed, sprites_command: nil}
  end

  defp generate_session_id do
    "exec_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp sprites_api_base do
    Application.get_env(:lattice, :resources)[:sprites_api_base] || "https://api.sprites.dev"
  end

  defp sprites_api_token do
    System.get_env("SPRITES_API_TOKEN") || raise "SPRITES_API_TOKEN not set"
  end

  defp sprites_api_token_safe do
    System.get_env("SPRITES_API_TOKEN")
  end
end
