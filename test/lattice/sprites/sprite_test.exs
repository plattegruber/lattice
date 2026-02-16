defmodule Lattice.Sprites.SpriteTest do
  use ExUnit.Case

  @moduletag :unit

  import Mox

  alias Lattice.Events
  alias Lattice.Events.HealthUpdate
  alias Lattice.Events.ReconciliationResult
  alias Lattice.Events.StateChange
  alias Lattice.Sprites.Sprite
  alias Lattice.Sprites.State

  # Mox requires verify_on_exit! for each test.
  # set_mox_global allows stubs to be called from any process (the GenServer).
  setup :set_mox_global
  setup :verify_on_exit!

  # Use a very long reconcile interval so tests control timing
  @long_interval 60_000

  # ── Helpers ─────────────────────────────────────────────────────────

  defp start_sprite(opts \\ []) do
    sprite_id =
      Keyword.get(opts, :sprite_id, "sprite-test-#{System.unique_integer([:positive])}")

    defaults = [
      sprite_id: sprite_id,
      reconcile_interval_ms: @long_interval,
      base_backoff_ms: Keyword.get(opts, :base_backoff_ms, 100),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, 1_000),
      max_retries: Keyword.get(opts, :max_retries, 10)
    ]

    merged = Keyword.merge(defaults, opts)
    {:ok, pid} = Sprite.start_link(merged)
    {pid, sprite_id}
  end

  # Stub get_sprite to return a specific observed status (atom).
  # This is the observation call that happens at the start of every reconciliation cycle.
  defp stub_observation(status) when is_atom(status) do
    Lattice.Capabilities.MockSprites
    |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: status}} end)
  end

  # ── Start & Init ────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts a Sprite GenServer" do
      stub_observation(:hibernating)
      {pid, _id} = start_sprite()
      assert Process.alive?(pid)
    end

    test "requires sprite_id option" do
      assert_raise KeyError, ~r/sprite_id/, fn ->
        Sprite.start_link(reconcile_interval_ms: @long_interval)
      end
    end

    test "accepts a name option" do
      stub_observation(:hibernating)
      name = :"sprite-named-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Sprite.start_link(
          sprite_id: "named-sprite",
          name: name,
          reconcile_interval_ms: @long_interval
        )

      assert Process.alive?(pid)
      assert GenServer.whereis(name) == pid
    end

    test "initializes with default hibernating state" do
      stub_observation(:hibernating)
      {pid, _id} = start_sprite()
      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :hibernating
      assert state.desired_state == :hibernating
    end

    test "initializes with custom desired state" do
      stub_observation(:hibernating)
      {pid, _id} = start_sprite(desired_state: :ready)
      {:ok, state} = Sprite.get_state(pid)
      assert state.desired_state == :ready
    end

    test "initializes with custom observed state" do
      stub_observation(:ready)
      {pid, _id} = start_sprite(observed_state: :ready)
      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :ready
    end
  end

  # ── get_state ───────────────────────────────────────────────────────

  describe "get_state/1" do
    test "returns the current state struct" do
      stub_observation(:hibernating)
      {pid, sprite_id} = start_sprite()
      {:ok, state} = Sprite.get_state(pid)

      assert %State{} = state
      assert state.sprite_id == sprite_id
    end
  end

  # ── set_desired_state ───────────────────────────────────────────────

  describe "set_desired_state/2" do
    test "updates the desired state" do
      stub_observation(:hibernating)
      {pid, _id} = start_sprite()
      assert :ok = Sprite.set_desired_state(pid, :ready)

      {:ok, state} = Sprite.get_state(pid)
      assert state.desired_state == :ready
    end

    test "rejects invalid desired state" do
      stub_observation(:hibernating)
      {pid, _id} = start_sprite()
      assert {:error, {:invalid_lifecycle, :bogus}} = Sprite.set_desired_state(pid, :bogus)
    end

    test "preserves state on error" do
      stub_observation(:hibernating)
      {pid, _id} = start_sprite()
      Sprite.set_desired_state(pid, :bogus)

      {:ok, state} = Sprite.get_state(pid)
      assert state.desired_state == :hibernating
    end
  end

  # ── Reconciliation: No Change ───────────────────────────────────────

  describe "reconciliation with no change needed" do
    test "emits no_change reconciliation result when states match" do
      # API says hibernating, desired is hibernating -> no change
      stub_observation(:hibernating)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_sprite(sprite_id)
      :ok = Events.subscribe_fleet()

      Sprite.reconcile_now(pid)

      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :no_change
                     },
                     1_000
    end

    test "resets backoff on no-change reconciliation" do
      stub_observation(:hibernating)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 0
    end
  end

  # ── Reconciliation: Observation Updates Observed State ──────────────

  describe "reconciliation observation from API" do
    test "updates observed state from API response" do
      # Sprite was initialized as hibernating but API says it is ready
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :ready}} end)

      {pid, sprite_id} = start_sprite(desired_state: :ready)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      # The API says ready, desired is ready, so we should see
      # an observation state change and a no_change reconciliation
      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :hibernating,
                       to_state: :ready
                     },
                     1_000

      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :no_change
                     },
                     1_000

      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :ready
      assert state.failure_count == 0
    end

    test "handles string status from API response" do
      # API returns string "running" which should be parsed to :ready
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: "running"}} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :ready
    end

    test "handles 'cold' API status as hibernating" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: "cold"}} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :hibernating
    end

    test "handles 'warm' API status as waking" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: "warm"}} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      # API says waking, but desired is ready, so attempt_transition may change it
      # The key thing is the API observation was parsed correctly
      assert state.observed_state in [:waking, :ready]
    end

    test "concurrent state change from another actor is detected" do
      # Sprite thinks it is :ready but API reports :hibernating (someone else stopped it)
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :hibernating}} end)
      |> stub(:wake, fn _id -> {:ok, %{id: "test", status: :waking}} end)

      {pid, sprite_id} = start_sprite(observed_state: :ready, desired_state: :ready)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      # Should detect the external change: ready -> hibernating
      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :ready,
                       to_state: :hibernating
                     },
                     1_000

      # Then attempt reconciliation since desired is :ready but observed is :hibernating
      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :hibernating,
                       to_state: :waking
                     },
                     1_000
    end
  end

  # ── Reconciliation: Successful Transition ───────────────────────────

  describe "reconciliation with transition" do
    test "transitions hibernating -> waking when desired is ready" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :hibernating}} end)
      |> stub(:wake, fn _id -> {:ok, %{id: "test", status: "running"}} end)

      {pid, sprite_id} = start_sprite(desired_state: :ready)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :hibernating,
                       to_state: :waking
                     },
                     1_000

      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :success
                     },
                     1_000
    end

    test "transitions waking -> ready on next reconciliation" do
      # API says still waking, but get_sprite in attempt_transition returns ready
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :ready}} end)

      {pid, sprite_id} = start_sprite(observed_state: :waking, desired_state: :ready)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      # The API observation says ready, which matches desired -> no transition needed
      # (observation itself triggers the state change from waking to ready)
      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :waking,
                       to_state: :ready
                     },
                     1_000
    end

    test "transitions ready -> busy" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :ready}} end)
      |> stub(:exec, fn _id, _cmd -> {:ok, %{exit_code: 0}} end)

      {pid, sprite_id} = start_sprite(observed_state: :ready, desired_state: :busy)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :ready,
                       to_state: :busy
                     },
                     1_000
    end

    test "transitions ready -> hibernating" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :ready}} end)
      |> stub(:sleep, fn _id -> {:ok, %{id: "test", status: "sleeping"}} end)

      {pid, sprite_id} = start_sprite(observed_state: :ready, desired_state: :hibernating)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :ready,
                       to_state: :hibernating
                     },
                     1_000
    end

    test "resets backoff on successful reconciliation" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :hibernating}} end)
      |> stub(:wake, fn _id -> {:ok, %{id: "test", status: "running"}} end)

      {pid, _id} = start_sprite(desired_state: :waking)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 0
    end

    test "uses real sprite_id in API calls" do
      test_sprite_id = "sprite-real-id-#{System.unique_integer([:positive])}"

      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn id ->
        # Verify the real sprite_id is passed, not "synthetic"
        assert id == test_sprite_id
        {:ok, %{id: id, status: :hibernating}}
      end)
      |> stub(:wake, fn id ->
        assert id == test_sprite_id
        {:ok, %{id: id, status: :waking}}
      end)

      {pid, ^test_sprite_id} = start_sprite(sprite_id: test_sprite_id, desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.sprite_id == test_sprite_id
    end
  end

  # ── Reconciliation: Failure & Backoff ───────────────────────────────

  describe "reconciliation failure and backoff" do
    test "increments failure count on API fetch failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, _id} = start_sprite(desired_state: :waking)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
    end

    test "increments failure count on transition failure" do
      # Observation succeeds, but the wake call fails
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :hibernating}} end)
      |> stub(:wake, fn _id -> {:error, :api_timeout} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
    end

    test "transitions to error state on fetch failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, sprite_id} = start_sprite(desired_state: :waking)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :hibernating,
                       to_state: :error
                     },
                     1_000

      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :failure
                     },
                     1_000
    end

    test "transitions to error state on transition failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :hibernating}} end)
      |> stub(:wake, fn _id -> {:error, :api_timeout} end)

      {pid, sprite_id} = start_sprite(desired_state: :waking)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :hibernating,
                       to_state: :error
                     },
                     1_000

      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :failure
                     },
                     1_000
    end

    test "accumulates failures with exponential backoff" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, _id} =
        start_sprite(desired_state: :waking, base_backoff_ms: 100, max_backoff_ms: 10_000)

      # First failure
      Sprite.reconcile_now(pid)
      Process.sleep(50)
      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
      assert state.backoff_ms == 100

      # Second failure (now in error state, trying to recover)
      Sprite.reconcile_now(pid)
      Process.sleep(50)
      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 2
      assert state.backoff_ms == 200
    end

    test "caps backoff at max" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, _id} =
        start_sprite(desired_state: :waking, base_backoff_ms: 100, max_backoff_ms: 200)

      # Accumulate many failures
      for _ <- 1..10 do
        Sprite.reconcile_now(pid)
        Process.sleep(20)
      end

      {:ok, state} = Sprite.get_state(pid)
      assert state.backoff_ms <= 200
    end

    test "recovery from error state resets backoff" do
      # First, cause a failure
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :timeout} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :error
      assert state.failure_count > 0

      # Now succeed on next attempt: API returns healthy state and wake succeeds
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :error}} end)
      |> stub(:wake, fn _id -> {:ok, %{id: "test", status: "running"}} end)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :waking
      assert state.failure_count == 0
      assert state.backoff_ms == 100
    end
  end

  # ── Edge Cases ──────────────────────────────────────────────────────

  describe "edge cases" do
    test "handles API not_found error (sprite removed externally)" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :not_found} end)

      {pid, sprite_id} = start_sprite(desired_state: :ready)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :failure,
                       details: "sprite not found in API"
                     },
                     1_000

      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :error
      assert state.failure_count == 1
    end

    test "handles API timeout gracefully" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :timeout} end)

      {pid, sprite_id} = start_sprite(desired_state: :ready)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :failure
                     },
                     1_000

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
      # Process should still be alive after timeout
      assert Process.alive?(pid)
    end

    test "handles rate limiting error" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :rate_limited} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
      assert Process.alive?(pid)
    end

    test "handles server error from API" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, {:server_error, 500, "Internal Server Error"}} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
      assert Process.alive?(pid)
    end

    test "handles API returning unknown status" do
      # API returns a status we do not recognize
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: "unknown_status"}} end)
      |> stub(:wake, fn _id -> {:ok, %{id: "test", status: :waking}} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      # Unknown status maps to :error, then reconciliation attempts recovery
      assert state.observed_state in [:error, :waking]
    end

    test "handles API response without status field" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", name: "no-status"}} end)
      |> stub(:wake, fn _id -> {:ok, %{id: "test", status: :waking}} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      # Missing status maps to :error, then reconciliation attempts recovery
      assert state.observed_state in [:error, :waking]
    end
  end

  # ── Health Assessment ───────────────────────────────────────────────

  describe "health assessment" do
    test "health is :ok when observed matches desired" do
      stub_observation(:hibernating)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.health == :ok
    end

    test "health is :converging when action taken" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :hibernating}} end)
      |> stub(:wake, fn _id -> {:ok, %{id: "test", status: :waking}} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      # After wake, observed is :waking, desired is :ready -> converging
      assert state.health == :converging
    end

    test "health is :degraded when retrying after failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, _id} = start_sprite(desired_state: :ready, max_retries: 10)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.health == :degraded
    end

    test "health is :error when max retries exceeded" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, _id} =
        start_sprite(
          desired_state: :ready,
          max_retries: 2,
          base_backoff_ms: 10,
          max_backoff_ms: 50
        )

      # Exhaust retries
      for _ <- 1..3 do
        Sprite.reconcile_now(pid)
        Process.sleep(20)
      end

      {:ok, state} = Sprite.get_state(pid)
      assert state.health == :error
      assert state.failure_count >= 2
    end

    test "emits health update event on health change" do
      stub_observation(:hibernating)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      # Health changes from :unknown to :ok
      assert_receive %HealthUpdate{
                       sprite_id: ^sprite_id,
                       status: :healthy
                     },
                     1_000
    end

    test "emits degraded health update on failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, sprite_id} = start_sprite(desired_state: :ready, max_retries: 10)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %HealthUpdate{
                       sprite_id: ^sprite_id,
                       status: :degraded
                     },
                     1_000
    end

    test "emits unhealthy health update when max retries exceeded" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, sprite_id} =
        start_sprite(
          desired_state: :ready,
          max_retries: 1,
          base_backoff_ms: 10,
          max_backoff_ms: 50
        )

      :ok = Events.subscribe_sprite(sprite_id)

      # First failure -> degraded (failure_count=1, max_retries=1 -> error)
      Sprite.reconcile_now(pid)

      assert_receive %HealthUpdate{
                       sprite_id: ^sprite_id,
                       status: :unhealthy
                     },
                     1_000
    end

    test "health recovers after successful reconciliation" do
      # Start with failure
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, sprite_id} = start_sprite(desired_state: :ready, max_retries: 10)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.health == :degraded

      # Now API recovers, returns desired state
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :ready}} end)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.health == :ok
      assert state.failure_count == 0
    end
  end

  # ── Backoff with Jitter ─────────────────────────────────────────────

  describe "backoff with jitter" do
    test "backoff delay includes jitter on failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, _id} =
        start_sprite(desired_state: :ready, base_backoff_ms: 1_000, max_backoff_ms: 10_000)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      # backoff_with_jitter should return a value near 1000 +/- 25%
      jittered = State.backoff_with_jitter(state)
      assert jittered >= 750
      assert jittered <= 1250
    end
  end

  # ── Last Observed At ────────────────────────────────────────────────

  describe "observation tracking" do
    test "records last_observed_at on successful API fetch" do
      stub_observation(:hibernating)

      {pid, _id} = start_sprite()

      # Initially nil
      {:ok, state} = Sprite.get_state(pid)
      assert state.last_observed_at == nil

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert %DateTime{} = state.last_observed_at
    end

    test "does not update last_observed_at on API failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :timeout} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.last_observed_at == nil
    end
  end

  # ── PubSub Broadcasting ────────────────────────────────────────────

  describe "PubSub broadcasting" do
    test "broadcasts state changes to fleet topic" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :hibernating}} end)
      |> stub(:wake, fn _id -> {:ok, %{id: "test", status: "running"}} end)

      {pid, sprite_id} = start_sprite(desired_state: :waking)

      :ok = Events.subscribe_fleet()

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{sprite_id: ^sprite_id}, 1_000
    end

    test "broadcasts reconciliation results to fleet topic" do
      stub_observation(:hibernating)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_fleet()

      Sprite.reconcile_now(pid)

      assert_receive %ReconciliationResult{sprite_id: ^sprite_id}, 1_000
    end

    test "broadcasts to per-sprite topic" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :hibernating}} end)
      |> stub(:wake, fn _id -> {:ok, %{id: "test", status: "running"}} end)

      {pid, sprite_id} = start_sprite(desired_state: :waking)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{sprite_id: ^sprite_id}, 1_000
      assert_receive %ReconciliationResult{sprite_id: ^sprite_id}, 1_000
    end

    test "broadcasts health updates to sprite topic" do
      stub_observation(:hibernating)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %HealthUpdate{sprite_id: ^sprite_id}, 1_000
    end

    test "broadcasts health updates to fleet topic" do
      stub_observation(:hibernating)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_fleet()

      Sprite.reconcile_now(pid)

      assert_receive %HealthUpdate{sprite_id: ^sprite_id}, 1_000
    end
  end

  # ── Telemetry Events ───────────────────────────────────────────────

  describe "telemetry events" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "sprite-test-#{inspect(ref)}"

      events = [
        [:lattice, :sprite, :state_change],
        [:lattice, :sprite, :reconciliation],
        [:lattice, :sprite, :health_update]
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

    test "emits telemetry on state change", %{ref: ref} do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :hibernating}} end)
      |> stub(:wake, fn _id -> {:ok, %{id: "test", status: "running"}} end)

      {pid, sprite_id} = start_sprite(desired_state: :waking)

      Sprite.reconcile_now(pid)

      assert_receive {:telemetry, ^ref, [:lattice, :sprite, :state_change], _measurements,
                      %{sprite_id: ^sprite_id}},
                     1_000
    end

    test "emits telemetry on reconciliation", %{ref: ref} do
      stub_observation(:hibernating)

      {pid, sprite_id} = start_sprite()

      Sprite.reconcile_now(pid)

      assert_receive {:telemetry, ^ref, [:lattice, :sprite, :reconciliation], _measurements,
                      %{sprite_id: ^sprite_id}},
                     1_000
    end

    test "emits telemetry on health update", %{ref: ref} do
      stub_observation(:hibernating)

      {pid, sprite_id} = start_sprite()

      Sprite.reconcile_now(pid)

      assert_receive {:telemetry, ^ref, [:lattice, :sprite, :health_update], _measurements,
                      %{sprite_id: ^sprite_id}},
                     1_000
    end
  end

  # ── Periodic Reconciliation ─────────────────────────────────────────

  describe "periodic reconciliation" do
    test "runs reconciliation on schedule" do
      stub_observation(:hibernating)

      {pid, sprite_id} = start_sprite(reconcile_interval_ms: 50)

      :ok = Events.subscribe_sprite(sprite_id)

      # Wait for at least one reconciliation cycle
      assert_receive %ReconciliationResult{sprite_id: ^sprite_id}, 500

      # Verify process is still alive
      assert Process.alive?(pid)
    end
  end

  # ── Max Retries ─────────────────────────────────────────────────────

  describe "max retries configuration" do
    test "accepts max_retries option" do
      stub_observation(:hibernating)

      {pid, _id} = start_sprite(max_retries: 5)

      {:ok, state} = Sprite.get_state(pid)
      assert state.max_retries == 5
    end

    test "defaults max_retries to 10" do
      stub_observation(:hibernating)

      {pid, _id} = start_sprite()

      {:ok, state} = Sprite.get_state(pid)
      assert state.max_retries == 10
    end
  end
end
