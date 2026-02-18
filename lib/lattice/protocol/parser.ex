defmodule Lattice.Protocol.Parser do
  @moduledoc """
  Parses stdout lines for LATTICE_EVENT structured events.

  Pure function module — no GenServer, no state. Transforms lines.
  """

  require Logger

  alias Lattice.Protocol.Event

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
      {:ok, %{"type" => type} = map} ->
        data = build_typed_data(type, map)
        event = Event.new(type, data)
        {:event, event}

      {:ok, _map} ->
        Logger.warning("LATTICE_EVENT missing 'type' field: #{json_str}")
        {:text, original_line}

      {:error, reason} ->
        Logger.warning("LATTICE_EVENT malformed JSON: #{inspect(reason)}")
        {:text, original_line}
    end
  end

  defp build_typed_data("artifact", map), do: Artifact.from_map(map)
  defp build_typed_data("question", map), do: Question.from_map(map)
  defp build_typed_data("assumption", map), do: Assumption.from_map(map)
  defp build_typed_data("blocked", map), do: Blocked.from_map(map)
  defp build_typed_data("progress", map), do: Progress.from_map(map)
  defp build_typed_data("completion", map), do: Completion.from_map(map)
  defp build_typed_data("warning", map), do: Warning.from_map(map)
  defp build_typed_data("checkpoint", map), do: Checkpoint.from_map(map)
  defp build_typed_data(_unknown_type, map), do: map
end
