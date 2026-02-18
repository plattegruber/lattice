defmodule Lattice.Sprites.Logs do
  @moduledoc """
  Context module for Sprite log aggregation.

  Combines logs from multiple sources into a unified stream:
  - Historical service logs from the Sprites API (via `fetch_logs/2`)
  - Exec session output (via PubSub)
  - Reconciliation and state transition events (via PubSub from Sprite GenServer)

  All sources feed into a single PubSub topic per sprite:
  `"sprite:<sprite_id>:logs"`.
  """

  alias Lattice.Capabilities.Sprites, as: SpritesCapability

  @type log_line :: %{
          id: integer(),
          source: :service | :exec | :reconciliation | :state_change | :health,
          level: :info | :warn | :error | :debug,
          message: String.t(),
          timestamp: DateTime.t()
        }

  @max_historical_lines 100

  @doc """
  Fetch historical logs for a sprite from the Sprites API.
  Returns a list of log_line maps suitable for seeding a LiveView stream.
  """
  @spec fetch_historical(String.t(), keyword()) :: [log_line()]
  def fetch_historical(sprite_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_historical_lines)

    case SpritesCapability.fetch_logs(sprite_id, limit: limit) do
      {:ok, raw_lines} ->
        raw_lines
        |> Enum.take(-limit)
        |> Enum.map(fn line ->
          %{
            id: System.unique_integer([:positive, :monotonic]),
            source: :service,
            level: :info,
            message: strip_ansi(line),
            timestamp: DateTime.utc_now()
          }
        end)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Build a log_line from a Sprite GenServer event.
  """
  @spec from_event(atom(), String.t(), map()) :: log_line()
  def from_event(event_type, _sprite_id, data) do
    {level, message} = format_event(event_type, data)

    %{
      id: System.unique_integer([:positive, :monotonic]),
      source: event_type,
      level: level,
      message: message,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Build a log_line from exec session output.
  """
  @spec from_exec_output(map()) :: log_line()
  def from_exec_output(%{stream: stream, chunk: chunk}) do
    level = if stream == :stderr, do: :error, else: :info

    %{
      id: System.unique_integer([:positive, :monotonic]),
      source: :exec,
      level: level,
      message: strip_ansi(to_string(chunk)),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Strip ANSI escape codes from a string.
  """
  @spec strip_ansi(String.t()) :: String.t()
  def strip_ansi(text) when is_binary(text) do
    Regex.replace(~r/\x1b\[[0-9;]*[a-zA-Z]/, text, "")
  end

  def strip_ansi(text), do: to_string(text)

  # -- Private --

  defp format_event(:state_change, %{from: from, to: to} = data) do
    reason = Map.get(data, :reason)
    msg = "State changed: #{from} -> #{to}" <> if(reason, do: " (#{reason})", else: "")
    {:info, msg}
  end

  defp format_event(:reconciliation, %{outcome: outcome} = data) do
    details = Map.get(data, :details)
    level = if outcome == :failure, do: :error, else: :info
    msg = "Reconciliation #{outcome}" <> if(details, do: ": #{details}", else: "")
    {level, msg}
  end

  defp format_event(:health, %{status: status} = data) do
    message = Map.get(data, :message)

    level =
      case status do
        :unhealthy -> :error
        :degraded -> :warn
        _ -> :info
      end

    msg = "Health: #{status}" <> if(message, do: " - #{message}", else: "")
    {level, msg}
  end

  defp format_event(type, data) do
    {:info, "#{type}: #{inspect(data)}"}
  end
end
