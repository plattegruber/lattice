defmodule Lattice.EventsTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Events
  alias Lattice.Events.ApprovalNeeded
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange

  # ── Topic Helpers ──────────────────────────────────────────────────

  describe "topic helpers" do
    test "sprite_topic/1 returns the per-sprite topic" do
      assert Events.sprite_topic("sprite-001") == "sprites:sprite-001"
    end

    test "fleet_topic/0 returns the fleet topic" do
      assert Events.fleet_topic() == "sprites:fleet"
    end

    test "approvals_topic/0 returns the approvals topic" do
      assert Events.approvals_topic() == "sprites:approvals"
    end
  end

  # ── PubSub Subscribe + Broadcast ───────────────────────────────────

  describe "subscribe_sprite/1 and broadcast_state_change/1" do
    test "delivers state change events to sprite subscribers" do
      :ok = Events.subscribe_sprite("sprite-pub-1")

      {:ok, event} = StateChange.new("sprite-pub-1", :cold, :warm)
      :ok = Events.broadcast_state_change(event)

      assert_receive %StateChange{sprite_id: "sprite-pub-1", to_state: :warm}
    end

    test "delivers state change events to fleet subscribers" do
      :ok = Events.subscribe_fleet()

      {:ok, event} = StateChange.new("sprite-fleet-1", :running, :cold)
      :ok = Events.broadcast_state_change(event)

      assert_receive %StateChange{sprite_id: "sprite-fleet-1", to_state: :cold}
    end
  end

  describe "broadcast_reconciliation_result/1" do
    test "delivers reconciliation events to sprite subscribers" do
      :ok = Events.subscribe_sprite("sprite-recon-1")

      {:ok, event} = ReconciliationResult.new("sprite-recon-1", :success, 42)
      :ok = Events.broadcast_reconciliation_result(event)

      assert_receive %ReconciliationResult{sprite_id: "sprite-recon-1", outcome: :success}
    end

    test "delivers reconciliation events to fleet subscribers" do
      :ok = Events.subscribe_fleet()

      {:ok, event} = ReconciliationResult.new("sprite-recon-2", :failure, 100)
      :ok = Events.broadcast_reconciliation_result(event)

      assert_receive %ReconciliationResult{sprite_id: "sprite-recon-2", outcome: :failure}
    end
  end

  describe "broadcast_approval_needed/1" do
    test "delivers approval events to sprite subscribers" do
      :ok = Events.subscribe_sprite("sprite-approval-1")

      {:ok, event} = ApprovalNeeded.new("sprite-approval-1", "deploy", :dangerous)
      :ok = Events.broadcast_approval_needed(event)

      assert_receive %ApprovalNeeded{sprite_id: "sprite-approval-1", action: "deploy"}
    end

    test "delivers approval events to fleet subscribers" do
      :ok = Events.subscribe_fleet()

      {:ok, event} = ApprovalNeeded.new("sprite-approval-2", "delete", :needs_review)
      :ok = Events.broadcast_approval_needed(event)

      assert_receive %ApprovalNeeded{sprite_id: "sprite-approval-2", action: "delete"}
    end

    test "delivers approval events to approvals subscribers" do
      :ok = Events.subscribe_approvals()

      {:ok, event} = ApprovalNeeded.new("sprite-approval-3", "force push", :dangerous)
      :ok = Events.broadcast_approval_needed(event)

      assert_receive %ApprovalNeeded{sprite_id: "sprite-approval-3", action: "force push"}
    end
  end

  # ── Sprite Logs ──────────────────────────────────────────────────────

  describe "sprite logs" do
    test "sprite_logs_topic/1 returns correct topic string" do
      assert Events.sprite_logs_topic("sprite-001") == "sprites:sprite-001:logs"
    end

    test "subscribe and broadcast round-trip" do
      Events.subscribe_sprite_logs("test-log-sprite")

      log_line = %{
        id: 1,
        source: :state_change,
        level: :info,
        message: "test log",
        timestamp: DateTime.utc_now()
      }

      Events.broadcast_sprite_log("test-log-sprite", log_line)

      assert_receive {:sprite_log, ^log_line}
    end
  end

  # ── Telemetry Emissions ────────────────────────────────────────────

  describe "telemetry events" do
    setup do
      test_pid = self()
      ref = make_ref()

      handler_id = "test-#{inspect(ref)}"

      events = [
        [:lattice, :sprite, :state_change],
        [:lattice, :sprite, :reconciliation],
        [:lattice, :sprite, :approval_needed],
        [:lattice, :capability, :call],
        [:lattice, :fleet, :summary]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{ref: ref}
    end

    test "broadcast_state_change emits telemetry", %{ref: ref} do
      :ok = Events.subscribe_sprite("sprite-tel-1")
      {:ok, event} = StateChange.new("sprite-tel-1", :warm, :running)
      Events.broadcast_state_change(event)

      assert_receive {:telemetry, ^ref, [:lattice, :sprite, :state_change], measurements,
                      metadata}

      assert %{system_time: _} = measurements
      assert metadata.sprite_id == "sprite-tel-1"
      assert metadata.event == event
    end

    test "broadcast_reconciliation_result emits telemetry", %{ref: ref} do
      :ok = Events.subscribe_sprite("sprite-tel-2")
      {:ok, event} = ReconciliationResult.new("sprite-tel-2", :success, 50)
      Events.broadcast_reconciliation_result(event)

      assert_receive {:telemetry, ^ref, [:lattice, :sprite, :reconciliation], _measurements,
                      metadata}

      assert metadata.sprite_id == "sprite-tel-2"
      assert metadata.event.outcome == :success
    end

    test "broadcast_approval_needed emits telemetry", %{ref: ref} do
      :ok = Events.subscribe_sprite("sprite-tel-4")
      {:ok, event} = ApprovalNeeded.new("sprite-tel-4", "rm -rf", :dangerous)
      Events.broadcast_approval_needed(event)

      assert_receive {:telemetry, ^ref, [:lattice, :sprite, :approval_needed], _measurements,
                      metadata}

      assert metadata.sprite_id == "sprite-tel-4"
      assert metadata.event.classification == :dangerous
    end

    test "emit_capability_call emits telemetry", %{ref: ref} do
      Events.emit_capability_call(:sprites, :list_sprites, 150, :ok)

      assert_receive {:telemetry, ^ref, [:lattice, :capability, :call], measurements, metadata}

      assert measurements.duration_ms == 150
      assert metadata.capability == :sprites
      assert metadata.operation == :list_sprites
      assert metadata.result == :ok
    end

    test "emit_capability_call handles error results", %{ref: ref} do
      Events.emit_capability_call(:github, :create_issue, 500, {:error, :timeout})

      assert_receive {:telemetry, ^ref, [:lattice, :capability, :call], measurements, metadata}

      assert measurements.duration_ms == 500
      assert metadata.capability == :github
      assert metadata.result == {:error, :timeout}
    end

    test "emit_fleet_summary emits telemetry", %{ref: ref} do
      summary = %{total: 10, by_state: %{running: 5, warm: 3, cold: 2}}
      Events.emit_fleet_summary(summary)

      assert_receive {:telemetry, ^ref, [:lattice, :fleet, :summary], measurements, metadata}

      assert measurements.total == 10
      assert metadata.by_state == %{running: 5, warm: 3, cold: 2}
    end

    test "emit_fleet_summary handles empty summary", %{ref: ref} do
      Events.emit_fleet_summary(%{})

      assert_receive {:telemetry, ^ref, [:lattice, :fleet, :summary], measurements, metadata}

      assert measurements.total == 0
      assert metadata.by_state == %{}
    end
  end
end
