defmodule Lattice.Events.TelemetryHandler do
  @moduledoc """
  Telemetry handler that logs Lattice domain events via `:logger`.

  Attaches to the Lattice telemetry event namespace and produces structured
  log output. This is the default observability layer — additional handlers
  (metrics exporters, StatsD, etc.) can be attached independently.

  ## Event Namespace

  All Lattice domain events live under the `[:lattice, ...]` namespace:

  - `[:lattice, :sprite, :state_change]` — Sprite state transitions
  - `[:lattice, :sprite, :reconciliation]` — Reconciliation cycle results
  - `[:lattice, :sprite, :health_update]` — Health check results
  - `[:lattice, :sprite, :approval_needed]` — Actions requiring approval
  - `[:lattice, :capability, :call]` — Capability module API calls
  - `[:lattice, :fleet, :summary]` — Fleet-level aggregate metrics
  - `[:lattice, :observation, :emitted]` — Sprite observation emitted
  - `[:lattice, :intent, :created]` — Intent created in the store
  - `[:lattice, :intent, :transitioned]` — Intent state transition
  - `[:lattice, :intent, :artifact_added]` — Artifact added to an intent

  ## Attaching

  Called during application startup:

      Lattice.Events.TelemetryHandler.attach()

  """

  require Logger

  @handler_id "lattice-events-logger"

  @events [
    [:lattice, :sprite, :state_change],
    [:lattice, :sprite, :reconciliation],
    [:lattice, :sprite, :health_update],
    [:lattice, :sprite, :approval_needed],
    [:lattice, :capability, :call],
    [:lattice, :fleet, :summary],
    [:lattice, :safety, :audit],
    [:lattice, :observation, :emitted],
    [:lattice, :intent, :created],
    [:lattice, :intent, :transitioned],
    [:lattice, :intent, :artifact_added]
  ]

  @doc """
  Attach the logger handler to all Lattice telemetry events.

  Returns `:ok`. Safe to call multiple times — duplicates are ignored by
  `:telemetry.attach_many/4` when the handler ID matches.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(
      @handler_id,
      @events,
      &handle_event/4,
      :no_config
    )
  end

  @doc """
  Detach the logger handler. Useful in tests to avoid noisy log output.
  """
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc "Returns the list of telemetry events this handler covers."
  @spec events() :: [list(atom())]
  def events, do: @events

  @doc "Returns the handler ID used for attachment."
  @spec handler_id() :: String.t()
  def handler_id, do: @handler_id

  # ── Handler Callbacks ──────────────────────────────────────────────

  @doc false
  def handle_event(
        [:lattice, :sprite, :state_change],
        _measurements,
        %{sprite_id: sprite_id, event: event},
        _config
      ) do
    Logger.info(
      "Sprite state change",
      sprite_id: sprite_id,
      from_state: event.from_state,
      to_state: event.to_state,
      reason: event.reason
    )
  end

  def handle_event(
        [:lattice, :sprite, :reconciliation],
        _measurements,
        %{sprite_id: sprite_id, event: event},
        _config
      ) do
    log_level = if event.outcome == :failure, do: :warning, else: :info

    Logger.log(
      log_level,
      "Sprite reconciliation #{event.outcome}",
      sprite_id: sprite_id,
      outcome: event.outcome,
      duration_ms: event.duration_ms,
      details: event.details
    )
  end

  def handle_event(
        [:lattice, :sprite, :health_update],
        _measurements,
        %{sprite_id: sprite_id, event: event},
        _config
      ) do
    log_level =
      case event.status do
        :healthy -> :info
        :degraded -> :warning
        :unhealthy -> :error
      end

    Logger.log(
      log_level,
      "Sprite health: #{event.status}",
      sprite_id: sprite_id,
      status: event.status,
      check_duration_ms: event.check_duration_ms,
      message: event.message
    )
  end

  def handle_event(
        [:lattice, :sprite, :approval_needed],
        _measurements,
        %{sprite_id: sprite_id, event: event},
        _config
      ) do
    Logger.warning(
      "Approval needed for #{event.classification} action",
      sprite_id: sprite_id,
      action: event.action,
      classification: event.classification
    )
  end

  def handle_event(
        [:lattice, :capability, :call],
        %{duration_ms: duration_ms},
        %{capability: capability, operation: operation, result: result},
        _config
      ) do
    log_level = if result == :ok, do: :info, else: :warning

    Logger.log(
      log_level,
      "Capability call #{capability}.#{operation}",
      capability: capability,
      operation: operation,
      duration_ms: duration_ms,
      result: inspect(result)
    )
  end

  def handle_event(
        [:lattice, :fleet, :summary],
        %{total: total},
        %{by_state: by_state},
        _config
      ) do
    Logger.info(
      "Fleet summary: #{total} sprites",
      total: total,
      by_state: inspect(by_state)
    )
  end

  def handle_event(
        [:lattice, :safety, :audit],
        _measurements,
        %{entry: entry},
        _config
      ) do
    log_level =
      case entry.result do
        :ok -> :info
        :denied -> :warning
        {:error, _} -> :warning
      end

    operator_info =
      case entry.operator do
        %{id: id, name: name} -> "#{name} (#{id})"
        _ -> "none"
      end

    Logger.log(
      log_level,
      "Audit: #{entry.capability}.#{entry.operation} [#{entry.classification}] -> #{inspect(entry.result)} by #{operator_info}",
      capability: entry.capability,
      operation: entry.operation,
      classification: entry.classification,
      result: inspect(entry.result),
      actor: entry.actor,
      args: inspect(entry.args)
    )
  end

  def handle_event(
        [:lattice, :observation, :emitted],
        _measurements,
        %{sprite_id: sprite_id, observation: observation},
        _config
      ) do
    log_level =
      case observation.severity do
        :info -> :info
        :low -> :info
        :medium -> :warning
        :high -> :warning
        :critical -> :error
      end

    Logger.log(
      log_level,
      "Observation emitted: #{observation.type} (#{observation.severity})",
      sprite_id: sprite_id,
      observation_id: observation.id,
      type: observation.type,
      severity: observation.severity
    )
  end

  def handle_event(
        [:lattice, :intent, :created],
        _measurements,
        %{intent: intent},
        _config
      ) do
    Logger.info(
      "Intent created: #{intent.id} (#{intent.kind})",
      intent_id: intent.id,
      kind: intent.kind,
      source: inspect(intent.source)
    )
  end

  def handle_event(
        [:lattice, :intent, :transitioned],
        _measurements,
        %{intent: intent, from: from, to: to},
        _config
      ) do
    Logger.info(
      "Intent transitioned: #{intent.id} #{from} -> #{to}",
      intent_id: intent.id,
      from: from,
      to: to
    )
  end

  def handle_event(
        [:lattice, :intent, :artifact_added],
        _measurements,
        %{intent: intent, artifact: artifact},
        _config
      ) do
    Logger.info(
      "Artifact added to intent: #{intent.id}",
      intent_id: intent.id,
      artifact_type: Map.get(artifact, :type, :unknown)
    )
  end
end
