defmodule LatticeWeb.Api.ExecController do
  @moduledoc """
  API controller for exec session management.

  Provides endpoints for starting, listing, inspecting, and terminating
  interactive exec sessions on sprites.
  """

  use LatticeWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Lattice.Sprites.ExecSession
  alias Lattice.Sprites.ExecSupervisor
  alias Lattice.Sprites.FleetManager

  tags(["Exec Sessions"])
  security([%{"BearerAuth" => []}])

  # ── POST /api/sprites/:id/exec ────────────────────────────────────

  @doc """
  Start a new exec session on a sprite.

  Body: `{ "command": "echo hello" }`
  """
  def create(conn, %{"id" => sprite_id, "command" => command}) do
    case FleetManager.get_sprite_pid(sprite_id) do
      {:ok, _pid} ->
        case ExecSupervisor.start_session(sprite_id: sprite_id, command: command) do
          {:ok, session_pid} ->
            {:ok, state} = ExecSession.get_state(session_pid)

            conn
            |> put_status(201)
            |> json(%{data: serialize_session(state), timestamp: DateTime.utc_now()})

          {:error, reason} ->
            conn
            |> put_status(500)
            |> json(%{
              error: "Failed to start session: #{inspect(reason)}",
              code: "SESSION_START_FAILED"
            })
        end

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Sprite not found", code: "SPRITE_NOT_FOUND"})
    end
  end

  def create(conn, %{"id" => _id}) do
    conn
    |> put_status(422)
    |> json(%{error: "Missing required field: command", code: "MISSING_FIELD"})
  end

  # ── GET /api/sprites/:id/sessions ─────────────────────────────────

  @doc """
  List active exec sessions for a sprite.
  """
  def index(conn, %{"id" => sprite_id}) do
    sessions = ExecSupervisor.list_sessions_for_sprite(sprite_id)

    session_data =
      sessions
      |> Enum.map(fn {_session_id, pid, _meta} ->
        case ExecSession.get_state(pid) do
          {:ok, state} -> serialize_session(state)
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    conn
    |> put_status(200)
    |> json(%{data: session_data, timestamp: DateTime.utc_now()})
  end

  # ── GET /api/sprites/:id/sessions/:session_id ─────────────────────

  @doc """
  Get session details with buffered output.
  """
  def show(conn, %{"id" => _sprite_id, "session_id" => session_id}) do
    case ExecSupervisor.get_session_pid(session_id) do
      {:ok, pid} ->
        with {:ok, state} <- ExecSession.get_state(pid),
             {:ok, output} <- ExecSession.get_output(pid) do
          conn
          |> put_status(200)
          |> json(%{
            data: Map.merge(serialize_session(state), %{output: serialize_output(output)}),
            timestamp: DateTime.utc_now()
          })
        end

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Session not found", code: "SESSION_NOT_FOUND"})
    end
  end

  # ── DELETE /api/sprites/:id/sessions/:session_id ──────────────────

  @doc """
  Terminate an exec session.
  """
  def delete(conn, %{"id" => _sprite_id, "session_id" => session_id}) do
    case ExecSupervisor.get_session_pid(session_id) do
      {:ok, pid} ->
        ExecSession.close(pid)

        conn
        |> put_status(200)
        |> json(%{
          data: %{session_id: session_id, status: "closed"},
          timestamp: DateTime.utc_now()
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Session not found", code: "SESSION_NOT_FOUND"})
    end
  end

  # ── Private ───────────────────────────────────────────────────────

  defp serialize_session(state) do
    %{
      session_id: state.session_id,
      sprite_id: state.sprite_id,
      command: state.command,
      status: state.status,
      started_at: state.started_at,
      exit_code: state.exit_code,
      buffer_size: state.buffer_size
    }
  end

  defp serialize_output(output) do
    Enum.map(output, fn entry ->
      %{stream: entry.stream, data: entry.data, timestamp: entry.timestamp}
    end)
  end
end
