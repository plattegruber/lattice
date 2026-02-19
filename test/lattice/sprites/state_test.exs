defmodule Lattice.Sprites.StateTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Sprites.State

  # ── Construction ────────────────────────────────────────────────────

  describe "new/2" do
    test "creates a state with defaults" do
      assert {:ok, state} = State.new("sprite-001")

      assert state.sprite_id == "sprite-001"
      assert state.status == :cold
      assert state.failure_count == 0
      assert state.backoff_ms == 1_000
      assert state.base_backoff_ms == 1_000
      assert state.max_backoff_ms == 60_000
      assert state.log_cursor == nil
      assert state.tags == %{}
      assert %DateTime{} = state.started_at
      assert %DateTime{} = state.updated_at
    end

    test "accepts custom status" do
      assert {:ok, state} = State.new("sprite-001", status: :warm)
      assert state.status == :warm
    end

    test "accepts custom backoff parameters" do
      assert {:ok, state} =
               State.new("sprite-001", base_backoff_ms: 500, max_backoff_ms: 30_000)

      assert state.base_backoff_ms == 500
      assert state.backoff_ms == 500
      assert state.max_backoff_ms == 30_000
    end

    test "accepts custom name" do
      assert {:ok, state} = State.new("sprite-001", name: "my-sprite")
      assert state.name == "my-sprite"
    end

    test "accepts custom tags" do
      assert {:ok, state} = State.new("sprite-001", tags: %{"env" => "prod"})
      assert state.tags == %{"env" => "prod"}
    end

    test "rejects invalid status" do
      assert {:error, {:invalid_status, :invalid}} =
               State.new("sprite-001", status: :invalid)
    end
  end

  # ── Status Updates ─────────────────────────────────────────────────

  describe "update_status/2" do
    test "updates status" do
      {:ok, state} = State.new("sprite-001")
      assert {:ok, new_state} = State.update_status(state, :warm)
      assert new_state.status == :warm
    end

    test "updates timestamp" do
      {:ok, state} = State.new("sprite-001")
      {:ok, new_state} = State.update_status(state, :warm)
      assert DateTime.compare(new_state.updated_at, state.updated_at) in [:gt, :eq]
    end

    test "rejects invalid status" do
      {:ok, state} = State.new("sprite-001")
      assert {:error, {:invalid_status, :flying}} = State.update_status(state, :flying)
    end

    test "allows all valid statuses" do
      {:ok, state} = State.new("sprite-001")

      for status <- State.valid_statuses() do
        assert {:ok, %State{status: ^status}} = State.update_status(state, status)
      end
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

  # ── Valid Statuses ────────────────────────────────────────────────

  describe "valid_statuses/0" do
    test "returns all valid statuses" do
      statuses = State.valid_statuses()
      assert :cold in statuses
      assert :warm in statuses
      assert :running in statuses
      assert length(statuses) == 3
    end
  end

  # ── Max Retries ─────────────────────────────────────────────────────

  describe "max_retries" do
    test "defaults to 10" do
      {:ok, state} = State.new("sprite-001")
      assert state.max_retries == 10
    end

    test "accepts custom max_retries" do
      {:ok, state} = State.new("sprite-001", max_retries: 5)
      assert state.max_retries == 5
    end
  end

  # ── Record Observation ──────────────────────────────────────────────

  describe "record_observation/1" do
    test "sets last_observed_at timestamp" do
      {:ok, state} = State.new("sprite-001")
      assert state.last_observed_at == nil

      state = State.record_observation(state)
      assert %DateTime{} = state.last_observed_at
    end

    test "updates updated_at timestamp" do
      {:ok, state} = State.new("sprite-001")
      state = State.record_observation(state)
      assert DateTime.compare(state.updated_at, state.started_at) in [:gt, :eq]
    end
  end

  # ── Display Name ──────────────────────────────────────────────────

  describe "display_name/1" do
    test "returns name when set" do
      {:ok, state} = State.new("sprite-001", name: "my-sprite")
      assert State.display_name(state) == "my-sprite"
    end

    test "falls back to sprite_id when name is nil" do
      {:ok, state} = State.new("sprite-001")
      assert State.display_name(state) == "sprite-001"
    end
  end

  # ── Tags ──────────────────────────────────────────────────────────

  describe "set_tags/2" do
    test "replaces tags" do
      {:ok, state} = State.new("sprite-001", tags: %{"old" => "value"})
      state = State.set_tags(state, %{"new" => "value"})
      assert state.tags == %{"new" => "value"}
    end

    test "updates timestamp" do
      {:ok, state} = State.new("sprite-001")
      state = State.set_tags(state, %{"env" => "prod"})
      assert DateTime.compare(state.updated_at, state.started_at) in [:gt, :eq]
    end
  end

  # ── Backoff with Jitter ─────────────────────────────────────────────

  describe "backoff_with_jitter/1" do
    test "returns a value near the backoff_ms" do
      {:ok, state} = State.new("sprite-001", base_backoff_ms: 1_000, max_backoff_ms: 60_000)
      state = State.record_failure(state)

      # Run multiple times to verify jitter varies
      results = for _ <- 1..100, do: State.backoff_with_jitter(state)

      # All results should be within +/- 25% of 1000
      assert Enum.all?(results, fn r -> r >= 750 and r <= 1250 end)
    end

    test "returns non-negative values for small backoffs" do
      {:ok, state} = State.new("sprite-001", base_backoff_ms: 1, max_backoff_ms: 100)
      state = State.record_failure(state)

      results = for _ <- 1..100, do: State.backoff_with_jitter(state)

      assert Enum.all?(results, fn r -> r >= 0 end)
    end

    test "jitter is bounded by max_backoff through backoff_ms" do
      {:ok, state} = State.new("sprite-001", base_backoff_ms: 100, max_backoff_ms: 200)

      state =
        Enum.reduce(1..20, state, fn _, acc -> State.record_failure(acc) end)

      # backoff_ms is capped at 200, jitter should be around that
      results = for _ <- 1..100, do: State.backoff_with_jitter(state)

      assert Enum.all?(results, fn r -> r >= 150 and r <= 250 end)
    end
  end

  # ── API Timestamps ──────────────────────────────────────────────────

  describe "update_api_timestamps/2" do
    test "stores timestamps from API response with string keys" do
      {:ok, state} = State.new("sprite-001")
      now = DateTime.utc_now()

      state =
        State.update_api_timestamps(state, %{
          "created_at" => DateTime.to_iso8601(now),
          "updated_at" => DateTime.to_iso8601(now),
          "last_started_at" => DateTime.to_iso8601(now),
          "last_active_at" => DateTime.to_iso8601(now)
        })

      assert %DateTime{} = state.api_created_at
      assert %DateTime{} = state.api_updated_at
      assert %DateTime{} = state.last_started_at
      assert %DateTime{} = state.last_active_at
    end

    test "ignores nil values without overwriting existing timestamps" do
      {:ok, state} = State.new("sprite-001")
      now = DateTime.utc_now()

      state = State.update_api_timestamps(state, %{"created_at" => DateTime.to_iso8601(now)})
      assert %DateTime{} = state.api_created_at

      # Passing nil should not overwrite
      state = State.update_api_timestamps(state, %{"created_at" => nil})
      assert %DateTime{} = state.api_created_at
    end

    test "handles missing keys gracefully" do
      {:ok, state} = State.new("sprite-001")
      state = State.update_api_timestamps(state, %{})

      assert state.api_created_at == nil
      assert state.api_updated_at == nil
      assert state.last_started_at == nil
      assert state.last_active_at == nil
    end

    test "accepts DateTime values directly" do
      {:ok, state} = State.new("sprite-001")
      now = DateTime.utc_now()

      state = State.update_api_timestamps(state, %{"created_at" => now})
      assert state.api_created_at == now
    end

    test "defaults to nil for all API timestamp fields" do
      {:ok, state} = State.new("sprite-001")
      assert state.api_created_at == nil
      assert state.api_updated_at == nil
      assert state.last_started_at == nil
      assert state.last_active_at == nil
    end
  end
end
