defmodule Lattice.Protocol.Parser do
  @moduledoc """
  Parses stdout lines for LATTICE_EVENT structured events.

  Supports both protocol v1 events (using `event_type` field) and legacy
  events (using `type` field). Pure function module — no GenServer, no state.
  """

  require Logger

  alias Lattice.Protocol.Event

  # Legacy event structs (pre-v1, still supported)
  alias Lattice.Protocol.Events.{
    Artifact,
    Assumption,
    Blocked,
    Checkpoint,
    Completion,
    Progress,
    Question,
    Warning
  }

  # Protocol v1 event structs
  alias Lattice.Protocol.Events.{
    ActionRequest,
    Completed,
    EnvironmentProposal,
    Error,
    Info,
    PhaseFinished,
    PhaseStarted,
    Waiting
  }

  @prefix "LATTICE_EVENT "

  @type parse_result :: {:event, Event.t()} | {:text, String.t()}

  @doc """
  Parse a single stdout line. Returns {:event, event} if LATTICE_EVENT prefix
  found and JSON is valid, {:text, line} otherwise.
  """
  @spec parse_line(String.t()) :: parse_result()
  def parse_line(line) when is_binary(line) do
    if String.starts_with?(line, @prefix) do
      json_str = String.trim_leading(line, @prefix)
      parse_event_json(json_str, line)
    else
      {:text, line}
    end
  end

  defp parse_event_json(json_str, original_line) do
    case Jason.decode(json_str) do
      {:ok, map} ->
        # Support both v1 envelope (event_type) and legacy (type)
        event_type = Map.get(map, "event_type") || Map.get(map, "type")

        if event_type do
          data = build_typed_data(event_type, map)

          event =
            Event.new(event_type, data,
              protocol_version: Map.get(map, "protocol_version", "v1"),
              sprite_id: Map.get(map, "sprite_id"),
              work_item_id: Map.get(map, "work_item_id"),
              run_id: Map.get(map, "work_item_id")
            )

          {:event, event}
        else
          Logger.warning("LATTICE_EVENT missing 'event_type'/'type' field: #{json_str}")
          {:text, original_line}
        end

      {:error, reason} ->
        Logger.warning("LATTICE_EVENT malformed JSON: #{inspect(reason)}")
        {:text, original_line}
    end
  end

  # ── Protocol v1 event types ──────────────────────────────────────────

  defp build_typed_data("INFO", map), do: Info.from_map(payload_or_root(map))
  defp build_typed_data("PHASE_STARTED", map), do: PhaseStarted.from_map(payload_or_root(map))
  defp build_typed_data("PHASE_FINISHED", map), do: PhaseFinished.from_map(payload_or_root(map))
  defp build_typed_data("ACTION_REQUEST", map), do: ActionRequest.from_map(payload_or_root(map))
  defp build_typed_data("ARTIFACT", map), do: Artifact.from_map(payload_or_root(map))
  defp build_typed_data("WAITING", map), do: Waiting.from_map(payload_or_root(map))
  defp build_typed_data("COMPLETED", map), do: Completed.from_map(payload_or_root(map))
  defp build_typed_data("ERROR", map), do: Error.from_map(payload_or_root(map))

  defp build_typed_data("ENVIRONMENT_PROPOSAL", map),
    do: EnvironmentProposal.from_map(payload_or_root(map))

  # ── Legacy event types (backward compatibility) ──────────────────────

  defp build_typed_data("artifact", map), do: Artifact.from_map(map)
  defp build_typed_data("question", map), do: Question.from_map(map)
  defp build_typed_data("assumption", map), do: Assumption.from_map(map)
  defp build_typed_data("blocked", map), do: Blocked.from_map(map)
  defp build_typed_data("progress", map), do: Progress.from_map(map)
  defp build_typed_data("completion", map), do: Completion.from_map(map)
  defp build_typed_data("warning", map), do: Warning.from_map(map)
  defp build_typed_data("checkpoint", map), do: Checkpoint.from_map(map)

  # ── Unknown types ────────────────────────────────────────────────────

  defp build_typed_data(_unknown_type, map), do: map

  # V1 events nest data in "payload", legacy events put it at the root
  defp payload_or_root(map) do
    case Map.get(map, "payload") do
      nil -> map
      payload when is_map(payload) -> payload
      _other -> map
    end
  end
end
