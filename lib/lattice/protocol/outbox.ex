defmodule Lattice.Protocol.Outbox do
  @moduledoc """
  Reliability layer for sprite protocol events.

  Sprites may write structured events to `/workspace/.lattice/outbox.jsonl`
  as a durable record. This module fetches, parses, and reconciles outbox
  events against those received via real-time streaming, ensuring no events
  are lost due to connection drops or timing issues.

  Each line in the outbox file is raw JSON (no `LATTICE_EVENT` prefix).
  """

  require Logger

  alias Lattice.Capabilities.Sprites
  alias Lattice.Protocol.Event
  alias Lattice.Protocol.Parser

  @outbox_path "/workspace/.lattice/outbox.jsonl"

  @doc """
  Fetch the outbox file from a sprite via exec.

  Returns `{:ok, content}` with the raw file content, `{:ok, nil}` if the
  file does not exist, or `{:error, reason}` if the sprite is unreachable.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch(sprite_name, _session_id) do
    command = "cat #{@outbox_path} 2>/dev/null; echo $?"

    case Sprites.exec(sprite_name, command) do
      {:ok, %{output: output, exit_code: 0}} ->
        parse_cat_output(output)

      {:ok, %{output: _output}} ->
        # Non-zero exit code from exec wrapper — file likely missing
        {:ok, nil}

      {:error, reason} ->
        Logger.warning(
          "Outbox fetch failed for sprite #{sprite_name}: #{inspect(reason)}, skipping"
        )

        {:error, reason}
    end
  end

  @doc """
  Parse JSONL content into a list of `%Event{}` structs.

  Each line is raw JSON (no `LATTICE_EVENT` prefix). Lines that fail to parse
  are skipped with a warning log. Returns only successfully parsed events.
  """
  @spec parse(String.t()) :: [Event.t()]
  def parse(content) when is_binary(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case parse_outbox_line(line) do
        {:ok, event} ->
          [event | acc]

        :skip ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  def parse(nil), do: []

  @doc """
  Reconcile streamed events with outbox events.

  Merges the two lists, deduplicating by matching on `type` + `timestamp`.
  When duplicates are found, the outbox version is preferred (it may be more
  complete since it was written after the event fully resolved).

  Events unique to either list are included in the result. The returned list
  is sorted by timestamp ascending.
  """
  @spec reconcile([Event.t()], [Event.t()]) :: [Event.t()]
  def reconcile(streamed_events, outbox_events) do
    # Index outbox events by {type, timestamp} for fast lookup
    outbox_index =
      Map.new(outbox_events, fn event ->
        {event_key(event), event}
      end)

    # Walk streamed events, replacing with outbox version when a match exists
    {merged, used_keys} =
      Enum.reduce(streamed_events, {[], MapSet.new()}, fn event, {acc, seen} ->
        key = event_key(event)

        case Map.get(outbox_index, key) do
          nil ->
            {[event | acc], seen}

          outbox_event ->
            {[outbox_event | acc], MapSet.put(seen, key)}
        end
      end)

    # Add outbox-only events (not matched to any streamed event)
    outbox_only =
      Enum.reject(outbox_events, fn event ->
        MapSet.member?(used_keys, event_key(event))
      end)

    (Enum.reverse(merged) ++ outbox_only)
    |> Enum.sort_by(& &1.timestamp, DateTime)
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp parse_cat_output(output) do
    # The command appends the exit code of `cat` as the last line.
    # If cat succeeded (exit code 0), return everything except the last line.
    # If cat failed (exit code non-zero), the file doesn't exist.
    lines = String.split(output, "\n")

    {content_lines, [exit_status_line]} =
      Enum.split(lines, max(length(lines) - 1, 0))

    case String.trim(exit_status_line) do
      "0" ->
        content = Enum.join(content_lines, "\n")

        if content == "" do
          {:ok, nil}
        else
          {:ok, content}
        end

      _nonzero ->
        {:ok, nil}
    end
  end

  defp parse_outbox_line(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      :skip
    else
      # Outbox lines are raw JSON — reuse parser by adding prefix
      case Parser.parse_line("LATTICE_EVENT " <> trimmed) do
        {:event, event} ->
          {:ok, event}

        {:text, _} ->
          Logger.warning("Outbox: malformed line, skipping: #{truncate(trimmed, 200)}")
          :skip
      end
    end
  end

  defp event_key(%Event{type: type, timestamp: timestamp}) do
    {type, timestamp}
  end

  defp truncate(string, max_length) when byte_size(string) <= max_length, do: string

  defp truncate(string, max_length) do
    String.slice(string, 0, max_length) <> "..."
  end
end
