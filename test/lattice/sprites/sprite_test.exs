defmodule Lattice.Sprites.SpriteTest do
  use ExUnit.Case

  @moduletag :unit

  import Mox

  alias Lattice.Events
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
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, 1_000)
    ]

    merged = Keyword.merge(defaults, opts)
    {:ok, pid} = Sprite.start_link(merged)
    {pid, sprite_id}
  end

  # ── Start & Init ────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts a Sprite GenServer" do
      {pid, _id} = start_sprite()
      assert Process.alive?(pid)
    end

    test "requires sprite_id option" do
      assert_raise KeyError, ~r/sprite_id/, fn ->
        Sprite.start_link(reconcile_interval_ms: @long_interval)
      end
    end

    test "accepts a name option" do
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
      {pid, _id} = start_sprite()
      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :hibernating
      assert state.desired_state == :hibernating
    end

    test "initializes with custom desired state" do
      {pid, _id} = start_sprite(desired_state: :ready)
      {:ok, state} = Sprite.get_state(pid)
      assert state.desired_state == :ready
    end

    test "initializes with custom observed state" do
      {pid, _id} = start_sprite(observed_state: :ready)
      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :ready
    end
  end

  # ── get_state ───────────────────────────────────────────────────────

  describe "get_state/1" do
    test "returns the current state struct" do
      {pid, sprite_id} = start_sprite()
      {:ok, state} = Sprite.get_state(pid)

      assert %State{} = state
      assert state.sprite_id == sprite_id
    end
  end

  # ── set_desired_state ───────────────────────────────────────────────

  describe "set_desired_state/2" do
    test "updates the desired state" do
      {pid, _id} = start_sprite()
      assert :ok = Sprite.set_desired_state(pid, :ready)

      {:ok, state} = Sprite.get_state(pid)
      assert state.desired_state == :ready
    end

    test "rejects invalid desired state" do
      {pid, _id} = start_sprite()
      assert {:error, {:invalid_lifecycle, :bogus}} = Sprite.set_desired_state(pid, :bogus)
    end

    test "preserves state on error" do
      {pid, _id} = start_sprite()
      Sprite.set_desired_state(pid, :bogus)

      {:ok, state} = Sprite.get_state(pid)
      assert state.desired_state == :hibernating
    end
  end

  # ── Reconciliation: No Change ───────────────────────────────────────

  describe "reconciliation with no change needed" do
    test "emits no_change reconciliation result when states match" do
      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_sprite(sprite_id)
      :ok = Events.subscribe_fleet()

      # Trigger reconciliation
      Sprite.reconcile_now(pid)

      # Should get a no_change result
      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :no_change
                     },
                     1_000
    end
  end

  # ── Reconciliation: Successful Transition ───────────────────────────

  describe "reconciliation with transition" do
    test "transitions hibernating -> waking when desired is ready" do
      Lattice.Capabilities.MockSprites
      |> stub(:wake, fn _id -> {:ok, %{id: "synthetic", status: "running"}} end)
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "synthetic", status: "running"}} end)

      {pid, sprite_id} = start_sprite(desired_state: :ready)

      :ok = Events.subscribe_sprite(sprite_id)

      # First reconcile: hibernating -> waking
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
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "synthetic", status: "running"}} end)

      {pid, sprite_id} = start_sprite(observed_state: :waking, desired_state: :ready)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :waking,
                       to_state: :ready
                     },
                     1_000
    end

    test "transitions ready -> busy" do
      Lattice.Capabilities.MockSprites
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
      |> stub(:sleep, fn _id -> {:ok, %{id: "synthetic", status: "sleeping"}} end)

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
      |> stub(:wake, fn _id -> {:ok, %{id: "synthetic", status: "running"}} end)

      {pid, _id} = start_sprite(desired_state: :waking)

      Sprite.reconcile_now(pid)

      # Allow time for async processing
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 0
    end
  end

  # ── Reconciliation: Failure & Backoff ───────────────────────────────

  describe "reconciliation failure and backoff" do
    test "increments failure count on reconciliation failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:wake, fn _id -> {:error, :api_timeout} end)

      {pid, _id} = start_sprite(desired_state: :waking)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
    end

    test "transitions to error state on failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:wake, fn _id -> {:error, :api_timeout} end)

      {pid, sprite_id} = start_sprite(desired_state: :waking)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      # Should receive a state change to error
      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :hibernating,
                       to_state: :error
                     },
                     1_000

      # And a failure reconciliation result
      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :failure
                     },
                     1_000
    end

    test "accumulates failures with exponential backoff" do
      Lattice.Capabilities.MockSprites
      |> stub(:wake, fn _id -> {:error, :api_timeout} end)

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
      |> stub(:wake, fn _id -> {:error, :api_timeout} end)

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
      |> stub(:wake, fn _id -> {:error, :timeout} end)

      {pid, _id} = start_sprite(desired_state: :ready)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :error
      assert state.failure_count > 0

      # Now succeed on next attempt
      Lattice.Capabilities.MockSprites
      |> stub(:wake, fn _id -> {:ok, %{id: "synthetic", status: "running"}} end)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.observed_state == :waking
      assert state.failure_count == 0
      assert state.backoff_ms == 100
    end
  end

  # ── PubSub Broadcasting ────────────────────────────────────────────

  describe "PubSub broadcasting" do
    test "broadcasts state changes to fleet topic" do
      Lattice.Capabilities.MockSprites
      |> stub(:wake, fn _id -> {:ok, %{id: "synthetic", status: "running"}} end)

      {pid, sprite_id} = start_sprite(desired_state: :waking)

      :ok = Events.subscribe_fleet()

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{sprite_id: ^sprite_id}, 1_000
    end

    test "broadcasts reconciliation results to fleet topic" do
      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_fleet()

      Sprite.reconcile_now(pid)

      assert_receive %ReconciliationResult{sprite_id: ^sprite_id}, 1_000
    end

    test "broadcasts to per-sprite topic" do
      Lattice.Capabilities.MockSprites
      |> stub(:wake, fn _id -> {:ok, %{id: "synthetic", status: "running"}} end)

      {pid, sprite_id} = start_sprite(desired_state: :waking)

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{sprite_id: ^sprite_id}, 1_000
      assert_receive %ReconciliationResult{sprite_id: ^sprite_id}, 1_000
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
        [:lattice, :sprite, :reconciliation]
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
      |> stub(:wake, fn _id -> {:ok, %{id: "synthetic", status: "running"}} end)

      {pid, sprite_id} = start_sprite(desired_state: :waking)

      Sprite.reconcile_now(pid)

      assert_receive {:telemetry, ^ref, [:lattice, :sprite, :state_change], _measurements,
                      %{sprite_id: ^sprite_id}},
                     1_000
    end

    test "emits telemetry on reconciliation", %{ref: ref} do
      {pid, sprite_id} = start_sprite()

      Sprite.reconcile_now(pid)

      assert_receive {:telemetry, ^ref, [:lattice, :sprite, :reconciliation], _measurements,
                      %{sprite_id: ^sprite_id}},
                     1_000
    end
  end

  # ── Periodic Reconciliation ─────────────────────────────────────────

  describe "periodic reconciliation" do
    test "runs reconciliation on schedule" do
      {pid, sprite_id} = start_sprite(reconcile_interval_ms: 50)

      :ok = Events.subscribe_sprite(sprite_id)

      # Wait for at least one reconciliation cycle
      assert_receive %ReconciliationResult{sprite_id: ^sprite_id}, 500

      # Verify process is still alive
      assert Process.alive?(pid)
    end
  end
end
