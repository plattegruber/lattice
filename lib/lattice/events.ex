defmodule Lattice.Events do
  @moduledoc """
  Event infrastructure for Lattice: PubSub broadcasting, topic conventions,
  and Telemetry integration.

  Events are the source of truth in Lattice. State changes emit Telemetry
  events (for metrics and logging) and PubSub broadcasts (for real-time
  fan-out to LiveView processes). The UI is a projection of the event stream.

  ## Topic Conventions

  - `"sprites:<sprite_id>"` — per-sprite events (state changes, health, logs)
  - `"sprites:fleet"` — fleet-wide notifications and summary updates
  - `"sprites:approvals"` — human-in-the-loop approval requests
  - `"observations:<sprite_id>"` — per-sprite observation events
  - `"observations:all"` — all observations across all sprites
  - `"intents"` — intent store mutations (create, transition, artifact)
  - `"intents:<intent_id>"` — per-intent pipeline events
  - `"intents:all"` — all intent pipeline events

  ## Usage

  Broadcasting an event:

      {:ok, event} = Lattice.Events.StateChange.new("sprite-001", :hibernating, :waking)
      Lattice.Events.broadcast_state_change(event)

  Subscribing from a LiveView:

      def mount(_params, _session, socket) do
        if connected?(socket) do
          Lattice.Events.subscribe_sprite("sprite-001")
          Lattice.Events.subscribe_fleet()
        end
        {:ok, socket}
      end

  Handling events in LiveView:

      def handle_info(%Lattice.Events.StateChange{} = event, socket) do
        # Update assigns based on the event
        {:noreply, assign(socket, :state, event.to_state)}
      end
  """

  alias Lattice.Events.ApprovalNeeded
  alias Lattice.Events.HealthUpdate
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange
  alias Lattice.Intents.Observation

  # ── Topic Helpers ──────────────────────────────────────────────────

  @doc "Returns the PubSub topic for a specific Sprite."
  @spec sprite_topic(String.t()) :: String.t()
  def sprite_topic(sprite_id) when is_binary(sprite_id) do
    "sprites:#{sprite_id}"
  end

  @doc "Returns the PubSub topic for fleet-wide events."
  @spec fleet_topic() :: String.t()
  def fleet_topic, do: "sprites:fleet"

  @doc "Returns the PubSub topic for approval events."
  @spec approvals_topic() :: String.t()
  def approvals_topic, do: "sprites:approvals"

  @doc "Returns the PubSub topic for safety audit events."
  @spec audit_topic() :: String.t()
  def audit_topic, do: "safety:audit"

  @doc "Returns the PubSub topic for intent store events."
  @spec intents_topic() :: String.t()
  def intents_topic, do: "intents"

  @doc "Returns the PubSub topic for a specific Sprite's observations."
  @spec observation_topic(String.t()) :: String.t()
  def observation_topic(sprite_id) when is_binary(sprite_id) do
    "observations:#{sprite_id}"
  end

  @doc "Returns the PubSub topic for all observations across all sprites."
  @spec observations_topic() :: String.t()
  def observations_topic, do: "observations:all"

  @doc "Returns the PubSub topic for a specific intent's pipeline events."
  @spec intent_topic(String.t()) :: String.t()
  def intent_topic(intent_id) when is_binary(intent_id) do
    "intents:#{intent_id}"
  end

  @doc "Returns the PubSub topic for all intent pipeline events."
  @spec intents_all_topic() :: String.t()
  def intents_all_topic, do: "intents:all"

  # ── Subscribe ──────────────────────────────────────────────────────

  @doc "Subscribe the calling process to events for a specific Sprite."
  @spec subscribe_sprite(String.t()) :: :ok | {:error, term()}
  def subscribe_sprite(sprite_id) do
    Phoenix.PubSub.subscribe(pubsub(), sprite_topic(sprite_id))
  end

  @doc "Subscribe the calling process to fleet-wide events."
  @spec subscribe_fleet() :: :ok | {:error, term()}
  def subscribe_fleet do
    Phoenix.PubSub.subscribe(pubsub(), fleet_topic())
  end

  @doc "Subscribe the calling process to approval events."
  @spec subscribe_approvals() :: :ok | {:error, term()}
  def subscribe_approvals do
    Phoenix.PubSub.subscribe(pubsub(), approvals_topic())
  end

  @doc "Subscribe the calling process to safety audit events."
  @spec subscribe_audit() :: :ok | {:error, term()}
  def subscribe_audit do
    Phoenix.PubSub.subscribe(pubsub(), audit_topic())
  end

  @doc "Subscribe the calling process to intent store events."
  @spec subscribe_intents() :: :ok | {:error, term()}
  def subscribe_intents do
    Phoenix.PubSub.subscribe(pubsub(), intents_topic())
  end

  @doc "Subscribe the calling process to observations for a specific Sprite."
  @spec subscribe_observations(String.t()) :: :ok | {:error, term()}
  def subscribe_observations(sprite_id) do
    Phoenix.PubSub.subscribe(pubsub(), observation_topic(sprite_id))
  end

  @doc "Subscribe the calling process to all observations across all sprites."
  @spec subscribe_all_observations() :: :ok | {:error, term()}
  def subscribe_all_observations do
    Phoenix.PubSub.subscribe(pubsub(), observations_topic())
  end

  @doc "Subscribe the calling process to pipeline events for a specific intent."
  @spec subscribe_intent(String.t()) :: :ok | {:error, term()}
  def subscribe_intent(intent_id) do
    Phoenix.PubSub.subscribe(pubsub(), intent_topic(intent_id))
  end

  @doc "Subscribe the calling process to all intent pipeline events."
  @spec subscribe_all_intents() :: :ok | {:error, term()}
  def subscribe_all_intents do
    Phoenix.PubSub.subscribe(pubsub(), intents_all_topic())
  end

  # ── Broadcast ──────────────────────────────────────────────────────

  @doc """
  Broadcast a Sprite state change event.

  Emits a Telemetry event and broadcasts to both the per-sprite topic and
  the fleet topic.
  """
  @spec broadcast_state_change(StateChange.t()) :: :ok | {:error, term()}
  def broadcast_state_change(%StateChange{} = event) do
    emit_telemetry([:lattice, :sprite, :state_change], event)
    broadcast_to_sprite(event.sprite_id, event)
    broadcast_to_fleet(event)
  end

  @doc """
  Broadcast a reconciliation result event.

  Emits a Telemetry event and broadcasts to both the per-sprite topic and
  the fleet topic.
  """
  @spec broadcast_reconciliation_result(ReconciliationResult.t()) :: :ok | {:error, term()}
  def broadcast_reconciliation_result(%ReconciliationResult{} = event) do
    emit_telemetry([:lattice, :sprite, :reconciliation], event)
    broadcast_to_sprite(event.sprite_id, event)
    broadcast_to_fleet(event)
  end

  @doc """
  Broadcast a health update event.

  Emits a Telemetry event and broadcasts to the per-sprite topic and
  the fleet topic.
  """
  @spec broadcast_health_update(HealthUpdate.t()) :: :ok | {:error, term()}
  def broadcast_health_update(%HealthUpdate{} = event) do
    emit_telemetry([:lattice, :sprite, :health_update], event)
    broadcast_to_sprite(event.sprite_id, event)
    broadcast_to_fleet(event)
  end

  @doc """
  Broadcast an approval needed event.

  Emits a Telemetry event and broadcasts to the per-sprite topic, the
  fleet topic, and the approvals topic.
  """
  @spec broadcast_approval_needed(ApprovalNeeded.t()) :: :ok | {:error, term()}
  def broadcast_approval_needed(%ApprovalNeeded{} = event) do
    emit_telemetry([:lattice, :sprite, :approval_needed], event)
    broadcast_to_sprite(event.sprite_id, event)
    broadcast_to_fleet(event)
    broadcast_to_approvals(event)
  end

  @doc """
  Broadcast an observation event.

  Emits a `[:lattice, :observation, :emitted]` Telemetry event and broadcasts
  to the per-sprite observation topic and the all-observations topic.
  """
  @spec broadcast_observation(Observation.t()) :: :ok | {:error, term()}
  def broadcast_observation(%Observation{} = observation) do
    :telemetry.execute(
      [:lattice, :observation, :emitted],
      %{system_time: System.system_time()},
      %{
        sprite_id: observation.sprite_id,
        observation: observation
      }
    )

    Phoenix.PubSub.broadcast(pubsub(), observation_topic(observation.sprite_id), observation)
    Phoenix.PubSub.broadcast(pubsub(), observations_topic(), observation)
  end

  # ── Telemetry ──────────────────────────────────────────────────────

  @doc """
  Emit a capability call telemetry event.

  Used by capability modules to instrument API call latency and outcome.

  ## Examples

      Lattice.Events.emit_capability_call(:sprites, :list_sprites, 150, :ok)
      Lattice.Events.emit_capability_call(:github, :create_issue, 500, {:error, :timeout})

  """
  @spec emit_capability_call(atom(), atom(), non_neg_integer(), :ok | {:error, term()}) :: :ok
  def emit_capability_call(capability, operation, duration_ms, result) do
    :telemetry.execute(
      [:lattice, :capability, :call],
      %{duration_ms: duration_ms},
      %{
        capability: capability,
        operation: operation,
        result: result,
        timestamp: DateTime.utc_now()
      }
    )
  end

  @doc """
  Emit a fleet summary telemetry event.

  Used periodically to report aggregate fleet statistics.

  ## Examples

      Lattice.Events.emit_fleet_summary(%{
        total: 10,
        by_state: %{ready: 5, busy: 3, hibernating: 2}
      })

  """
  @spec emit_fleet_summary(map()) :: :ok
  def emit_fleet_summary(summary) when is_map(summary) do
    :telemetry.execute(
      [:lattice, :fleet, :summary],
      %{total: Map.get(summary, :total, 0)},
      %{
        by_state: Map.get(summary, :by_state, %{}),
        timestamp: DateTime.utc_now()
      }
    )
  end

  # ── Private ────────────────────────────────────────────────────────

  defp emit_telemetry(event_name, %{sprite_id: sprite_id} = event) do
    :telemetry.execute(
      event_name,
      %{system_time: System.system_time()},
      %{
        sprite_id: sprite_id,
        event: event
      }
    )
  end

  defp broadcast_to_sprite(sprite_id, event) do
    Phoenix.PubSub.broadcast(pubsub(), sprite_topic(sprite_id), event)
  end

  defp broadcast_to_fleet(event) do
    Phoenix.PubSub.broadcast(pubsub(), fleet_topic(), event)
  end

  defp broadcast_to_approvals(event) do
    Phoenix.PubSub.broadcast(pubsub(), approvals_topic(), event)
  end

  defp pubsub, do: Lattice.PubSub
end
