defmodule Lattice.Events.TelemetryHandlerTest do
  use ExUnit.Case

  require Logger

  @moduletag :unit

  alias Lattice.Events.ApprovalNeeded
  alias Lattice.Events.HealthUpdate
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange
  alias Lattice.Events.TelemetryHandler

  describe "attach/0 and detach/0" do
    test "attach registers the handler and detach removes it" do
      # Detach first in case application startup already attached it
      TelemetryHandler.detach()

      # Verify we can attach
      assert :ok = TelemetryHandler.attach()

      # Attaching again returns already_exists
      assert {:error, :already_exists} = TelemetryHandler.attach()

      # Detach succeeds
      assert :ok = TelemetryHandler.detach()

      # Re-attach for other tests / application use
      TelemetryHandler.attach()
    end
  end

  describe "events/0" do
    test "returns all Lattice telemetry event names" do
      events = TelemetryHandler.events()

      assert [:lattice, :sprite, :state_change] in events
      assert [:lattice, :sprite, :reconciliation] in events
      assert [:lattice, :sprite, :health_update] in events
      assert [:lattice, :sprite, :approval_needed] in events
      assert [:lattice, :capability, :call] in events
      assert [:lattice, :fleet, :summary] in events
      assert [:lattice, :safety, :audit] in events
      assert [:lattice, :observation, :emitted] in events
      assert [:lattice, :intent, :created] in events
      assert [:lattice, :intent, :transitioned] in events
      assert [:lattice, :intent, :artifact_added] in events
      assert length(events) == 11
    end
  end

  describe "handler_id/0" do
    test "returns the handler ID string" do
      assert is_binary(TelemetryHandler.handler_id())
    end
  end

  describe "handle_event/4 (integration — log output)" do
    import ExUnit.CaptureLog

    setup do
      # Ensure the handler is attached
      TelemetryHandler.detach()
      TelemetryHandler.attach()

      # Lower the log level so we can capture info-level messages
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      :ok
    end

    test "logs state change events" do
      {:ok, event} =
        StateChange.new("sprite-log-1", :hibernating, :waking, reason: "scheduled wake")

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:lattice, :sprite, :state_change],
            %{system_time: System.system_time()},
            %{sprite_id: "sprite-log-1", event: event}
          )
        end)

      assert log =~ "Sprite state change"
    end

    test "logs reconciliation success at info level" do
      {:ok, event} = ReconciliationResult.new("sprite-log-2", :success, 42)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:lattice, :sprite, :reconciliation],
            %{system_time: System.system_time()},
            %{sprite_id: "sprite-log-2", event: event}
          )
        end)

      assert log =~ "reconciliation success"
    end

    test "logs reconciliation failure at warning level" do
      {:ok, event} =
        ReconciliationResult.new("sprite-log-3", :failure, 100, details: "API down")

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:lattice, :sprite, :reconciliation],
            %{system_time: System.system_time()},
            %{sprite_id: "sprite-log-3", event: event}
          )
        end)

      assert log =~ "reconciliation failure"
    end

    test "logs unhealthy health updates at error level" do
      {:ok, event} =
        HealthUpdate.new("sprite-log-4", :unhealthy, 5000, message: "unreachable")

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:lattice, :sprite, :health_update],
            %{system_time: System.system_time()},
            %{sprite_id: "sprite-log-4", event: event}
          )
        end)

      assert log =~ "health: unhealthy"
    end

    test "logs approval needed events at warning level" do
      {:ok, event} =
        ApprovalNeeded.new("sprite-log-5", "force push", :dangerous)

      log =
        capture_log(fn ->
          :telemetry.execute(
            [:lattice, :sprite, :approval_needed],
            %{system_time: System.system_time()},
            %{sprite_id: "sprite-log-5", event: event}
          )
        end)

      assert log =~ "Approval needed"
      assert log =~ "dangerous"
    end

    test "logs successful capability calls at info level" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:lattice, :capability, :call],
            %{duration_ms: 150},
            %{
              capability: :sprites,
              operation: :list_sprites,
              result: :ok,
              timestamp: DateTime.utc_now()
            }
          )
        end)

      assert log =~ "Capability call sprites.list_sprites"
    end

    test "logs failed capability calls at warning level" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:lattice, :capability, :call],
            %{duration_ms: 500},
            %{
              capability: :github,
              operation: :create_issue,
              result: {:error, :timeout},
              timestamp: DateTime.utc_now()
            }
          )
        end)

      assert log =~ "Capability call github.create_issue"
    end

    test "logs fleet summary events" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:lattice, :fleet, :summary],
            %{total: 10},
            %{
              by_state: %{ready: 5, busy: 3, hibernating: 2},
              timestamp: DateTime.utc_now()
            }
          )
        end)

      assert log =~ "Fleet summary: 10 sprites"
    end
  end
end
