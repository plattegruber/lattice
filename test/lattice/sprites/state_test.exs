defmodule Lattice.Sprites.StateTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Sprites.State

  # ── Construction ────────────────────────────────────────────────────

  describe "new/2" do
    test "creates a state with defaults" do
      assert {:ok, state} = State.new("sprite-001")

      assert state.sprite_id == "sprite-001"
      assert state.observed_state == :hibernating
      assert state.desired_state == :hibernating
      assert state.health == :unknown
      assert state.failure_count == 0
      assert state.backoff_ms == 1_000
      assert state.base_backoff_ms == 1_000
      assert state.max_backoff_ms == 60_000
      assert state.log_cursor == nil
      assert %DateTime{} = state.started_at
      assert %DateTime{} = state.updated_at
    end

    test "accepts custom desired_state" do
      assert {:ok, state} = State.new("sprite-001", desired_state: :ready)
      assert state.desired_state == :ready
    end

    test "accepts custom observed_state" do
      assert {:ok, state} = State.new("sprite-001", observed_state: :busy)
      assert state.observed_state == :busy
    end

    test "accepts custom backoff parameters" do
      assert {:ok, state} =
               State.new("sprite-001", base_backoff_ms: 500, max_backoff_ms: 30_000)

      assert state.base_backoff_ms == 500
      assert state.backoff_ms == 500
      assert state.max_backoff_ms == 30_000
    end

    test "rejects invalid desired_state" do
      assert {:error, {:invalid_lifecycle, :invalid}} =
               State.new("sprite-001", desired_state: :invalid)
    end

    test "rejects invalid observed_state" do
      assert {:error, {:invalid_lifecycle, :bogus}} =
               State.new("sprite-001", observed_state: :bogus)
    end
  end

  # ── Transitions ─────────────────────────────────────────────────────

  describe "transition/2" do
    test "updates observed state" do
      {:ok, state} = State.new("sprite-001")
      assert {:ok, new_state} = State.transition(state, :waking)
      assert new_state.observed_state == :waking
    end

    test "updates timestamp" do
      {:ok, state} = State.new("sprite-001")
      {:ok, new_state} = State.transition(state, :waking)
      assert DateTime.compare(new_state.updated_at, state.updated_at) in [:gt, :eq]
    end

    test "rejects invalid state" do
      {:ok, state} = State.new("sprite-001")
      assert {:error, {:invalid_lifecycle, :flying}} = State.transition(state, :flying)
    end

    test "allows all valid lifecycle states" do
      {:ok, state} = State.new("sprite-001")

      for lifecycle <- State.valid_lifecycle_states() do
        assert {:ok, %State{observed_state: ^lifecycle}} = State.transition(state, lifecycle)
      end
    end
  end

  # ── Set Desired ─────────────────────────────────────────────────────

  describe "set_desired/2" do
    test "updates desired state" do
      {:ok, state} = State.new("sprite-001")
      assert {:ok, new_state} = State.set_desired(state, :ready)
      assert new_state.desired_state == :ready
    end

    test "updates timestamp" do
      {:ok, state} = State.new("sprite-001")
      {:ok, new_state} = State.set_desired(state, :ready)
      assert DateTime.compare(new_state.updated_at, state.updated_at) in [:gt, :eq]
    end

    test "rejects invalid state" do
      {:ok, state} = State.new("sprite-001")
      assert {:error, {:invalid_lifecycle, :nope}} = State.set_desired(state, :nope)
    end
  end

  # ── Backoff & Failure Tracking ──────────────────────────────────────

  describe "record_failure/1" do
    test "increments failure count" do
      {:ok, state} = State.new("sprite-001")
      state = State.record_failure(state)
      assert state.failure_count == 1
    end

    test "applies exponential backoff" do
      {:ok, state} = State.new("sprite-001", base_backoff_ms: 100, max_backoff_ms: 10_000)

      state = State.record_failure(state)
      # 100 * 2^0 = 100
      assert state.backoff_ms == 100

      state = State.record_failure(state)
      # 100 * 2^1 = 200
      assert state.backoff_ms == 200

      state = State.record_failure(state)
      # 100 * 2^2 = 400
      assert state.backoff_ms == 400

      state = State.record_failure(state)
      # 100 * 2^3 = 800
      assert state.backoff_ms == 800
    end

    test "caps backoff at max" do
      {:ok, state} = State.new("sprite-001", base_backoff_ms: 100, max_backoff_ms: 500)

      state =
        Enum.reduce(1..10, state, fn _, acc -> State.record_failure(acc) end)

      assert state.backoff_ms == 500
    end

    test "tracks consecutive failures" do
      {:ok, state} = State.new("sprite-001")

      state =
        Enum.reduce(1..5, state, fn _, acc -> State.record_failure(acc) end)

      assert state.failure_count == 5
    end
  end

  describe "reset_backoff/1" do
    test "resets failure count to zero" do
      {:ok, state} = State.new("sprite-001")
      state = State.record_failure(state)
      state = State.record_failure(state)
      state = State.reset_backoff(state)
      assert state.failure_count == 0
    end

    test "resets backoff to base value" do
      {:ok, state} = State.new("sprite-001", base_backoff_ms: 200)
      state = State.record_failure(state)
      state = State.record_failure(state)
      state = State.reset_backoff(state)
      assert state.backoff_ms == 200
    end
  end

  # ── Needs Reconciliation ────────────────────────────────────────────

  describe "needs_reconciliation?/1" do
    test "returns false when observed matches desired" do
      {:ok, state} = State.new("sprite-001")
      refute State.needs_reconciliation?(state)
    end

    test "returns true when observed differs from desired" do
      {:ok, state} = State.new("sprite-001", desired_state: :ready)
      assert State.needs_reconciliation?(state)
    end
  end

  # ── Valid States ────────────────────────────────────────────────────

  describe "valid_lifecycle_states/0" do
    test "returns all lifecycle states" do
      states = State.valid_lifecycle_states()
      assert :hibernating in states
      assert :waking in states
      assert :ready in states
      assert :busy in states
      assert :error in states
      assert length(states) == 5
    end
  end
end
