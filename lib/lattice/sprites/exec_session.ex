defmodule Lattice.Sprites.ExecSession do
  @moduledoc """
  GenServer managing a WebSocket exec session with a sprite.

  Connects to WSS /v1/sprites/{name}/exec, sends commands, and streams
  output chunks via PubSub. Maintains an output buffer for replay.
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
    :conn_pid,
    :stream_ref,
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
    case connect_ws(state.sprite_id, state.command) do
      {:ok, conn_pid, stream_ref} ->
        new_state = %{
          state
          | conn_pid: conn_pid,
            stream_ref: stream_ref,
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

  # Handle gun WebSocket frames
  @impl true
  def handle_info({:gun_ws, _conn_pid, _stream_ref, {:text, data}}, state) do
    state = cancel_idle_timer(state)

    case Jason.decode(data) do
      {:ok, %{"type" => "stdout", "data" => chunk}} ->
        new_state = handle_output_chunk(state, :stdout, chunk)
        {:noreply, reset_idle_timer(new_state)}

      {:ok, %{"type" => "stderr", "data" => chunk}} ->
        new_state = handle_output_chunk(state, :stderr, chunk)
        {:noreply, reset_idle_timer(new_state)}

      {:ok, %{"type" => "exit", "exit_code" => code}} ->
        new_state = %{state | exit_code: code, status: :closed}

        :telemetry.execute(
          [:lattice, :exec, :completed],
          %{count: 1, exit_code: code},
          %{session_id: state.session_id, sprite_id: state.sprite_id}
        )

        broadcast_output(new_state, :exit, "Process exited with code #{code}")
        {:stop, :normal, new_state}

      {:ok, %{"type" => type, "data" => chunk}} ->
        new_state = handle_output_chunk(state, :stdout, chunk)
        Logger.debug("Unknown frame type: #{type}")
        {:noreply, reset_idle_timer(new_state)}

      {:ok, _other} ->
        {:noreply, reset_idle_timer(state)}

      {:error, _} ->
        new_state = handle_output_chunk(state, :stdout, data)
        {:noreply, reset_idle_timer(new_state)}
    end
  end

  # Handle binary WebSocket frames (raw output)
  def handle_info({:gun_ws, _conn_pid, _stream_ref, {:binary, data}}, state) do
    state = cancel_idle_timer(state)
    new_state = handle_output_chunk(state, :stdout, data)
    {:noreply, reset_idle_timer(new_state)}
  end

  # WebSocket closed by server
  def handle_info({:gun_ws, _conn_pid, _stream_ref, :close}, state) do
    Logger.info("Exec session #{state.session_id} closed by server")
    {:stop, :normal, %{state | status: :closed}}
  end

  def handle_info({:gun_ws, _conn_pid, _stream_ref, {:close, code, reason}}, state) do
    Logger.info("Exec session #{state.session_id} closed: #{code} #{reason}")
    {:stop, :normal, %{state | status: :closed}}
  end

  # Gun connection down
  def handle_info({:gun_down, _conn_pid, _protocol, reason, _killed_streams}, state) do
    Logger.warning("Exec session #{state.session_id} connection down: #{inspect(reason)}")
    {:stop, {:shutdown, {:connection_down, reason}}, %{state | status: :closed}}
  end

  # Gun upgrade success (WebSocket handshake completed)
  # Command is already passed via the `cmd` query parameter on the upgrade URL,
  # so no need to send it again via stdin frame.
  def handle_info({:gun_upgrade, _conn_pid, _stream_ref, ["websocket"], _headers}, state) do
    Logger.debug("Exec session #{state.session_id} WebSocket upgrade successful")
    {:noreply, state}
  end

  # Gun response (non-upgrade)
  def handle_info({:gun_response, _conn_pid, _stream_ref, _fin, status, _headers}, state) do
    Logger.error(
      "Exec session #{state.session_id} got HTTP #{status} instead of WebSocket upgrade"
    )

    {:stop, {:shutdown, {:upgrade_failed, status}}, state}
  end

  # Idle timeout
  def handle_info(:idle_timeout, state) do
    Logger.info("Exec session #{state.session_id} idle timeout after #{state.idle_timeout}ms")
    new_state = do_close(state)
    {:stop, :normal, new_state}
  end

  # Catch-all for gun messages we don't handle
  def handle_info(msg, state) do
    Logger.debug("Exec session #{state.session_id} unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn_pid && Process.alive?(state.conn_pid) do
      :gun.close(state.conn_pid)
    end

    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp connect_ws(sprite_id, command) do
    base_url = sprites_api_base()
    token = sprites_api_token()

    uri = URI.parse(base_url)
    host = String.to_charlist(uri.host)
    port = uri.port || if(uri.scheme == "https", do: 443, else: 80)
    transport = if uri.scheme == "https", do: :tls, else: :tcp

    gun_opts = %{
      protocols: [:http],
      transport: transport,
      tls_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    }

    case :gun.open(host, port, gun_opts) do
      {:ok, conn_pid} ->
        case :gun.await_up(conn_pid, 10_000) do
          {:ok, _protocol} ->
            query = URI.encode_query([{"cmd", command}])
            path = "/v1/sprites/#{URI.encode(sprite_id)}/exec?#{query}"

            headers = [
              {"authorization", "Bearer #{token}"}
            ]

            stream_ref = :gun.ws_upgrade(conn_pid, String.to_charlist(path), headers)
            {:ok, conn_pid, stream_ref}

          {:error, reason} ->
            :gun.close(conn_pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
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
    if state.conn_pid && Process.alive?(state.conn_pid) do
      :gun.close(state.conn_pid)
    end

    state = cancel_idle_timer(state)
    %{state | status: :closed, conn_pid: nil}
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
