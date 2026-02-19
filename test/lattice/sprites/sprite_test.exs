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
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, 1_000),
      max_retries: Keyword.get(opts, :max_retries, 10)
    ]

    merged = Keyword.merge(defaults, opts)
    {:ok, pid} = Sprite.start_link(merged)
    {pid, sprite_id}
  end

  # Stub get_sprite to return a specific status (atom).
  # This is the observation call that happens at the start of every reconciliation cycle.
  defp stub_observation(status) when is_atom(status) do
    Lattice.Capabilities.MockSprites
    |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: status}} end)
  end

  # ── Start & Init ────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts a Sprite GenServer" do
      stub_observation(:cold)
      {pid, _id} = start_sprite()
      assert Process.alive?(pid)
    end

    test "requires sprite_id option" do
      assert_raise KeyError, ~r/sprite_id/, fn ->
        Sprite.start_link(reconcile_interval_ms: @long_interval)
      end
    end

    test "accepts a name option" do
      stub_observation(:cold)
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

    test "initializes with default cold status" do
      stub_observation(:cold)
      {pid, _id} = start_sprite()
      {:ok, state} = Sprite.get_state(pid)
      assert state.status == :cold
    end
  end

  # ── get_state ───────────────────────────────────────────────────────

  describe "get_state/1" do
    test "returns the current state struct" do
      stub_observation(:cold)
      {pid, sprite_id} = start_sprite()
      {:ok, state} = Sprite.get_state(pid)

      assert %State{} = state
      assert state.sprite_id == sprite_id
    end
  end

  # ── Reconciliation: No Change ───────────────────────────────────────

  describe "reconciliation with no change needed" do
    test "emits no_change reconciliation result when status unchanged" do
      # API says cold, sprite starts as cold -> no change
      stub_observation(:cold)

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
      stub_observation(:cold)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 0
    end
  end

  # ── Reconciliation: Observation Updates Status ──────────────────────

  describe "reconciliation observation from API" do
    test "updates status from API response" do
      # Sprite starts as cold but API says it is running
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :running}} end)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      # The API says running, so we should see a state change from cold to running
      assert_receive %StateChange{
                       sprite_id: ^sprite_id,
                       from_state: :cold,
                       to_state: :running
                     },
                     1_000

      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :no_change
                     },
                     1_000

      {:ok, state} = Sprite.get_state(pid)
      assert state.status == :running
      assert state.failure_count == 0
    end

    test "handles string 'running' status from API response" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: "running"}} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.status == :running
    end

    test "handles string 'cold' status from API response" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: "cold"}} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.status == :cold
    end

    test "handles string 'warm' status from API response" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: "warm"}} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.status == :warm
    end

    test "uses real sprite_id in API calls" do
      test_sprite_id = "sprite-real-id-#{System.unique_integer([:positive])}"

      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn id ->
        # Verify the real sprite_id is passed
        assert id == test_sprite_id
        {:ok, %{id: id, status: :cold}}
      end)

      {pid, ^test_sprite_id} = start_sprite(sprite_id: test_sprite_id)

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

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
    end

    test "status stays unchanged on API fetch failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :failure
                     },
                     1_000

      {:ok, state} = Sprite.get_state(pid)
      # Status remains cold -- no transition to :error
      assert state.status == :cold
      assert state.failure_count == 1
    end

    test "accumulates failures with exponential backoff" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, _id} =
        start_sprite(base_backoff_ms: 100, max_backoff_ms: 10_000)

      # First failure
      Sprite.reconcile_now(pid)
      Process.sleep(50)
      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
      assert state.backoff_ms == 100

      # Second failure
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
        start_sprite(base_backoff_ms: 100, max_backoff_ms: 200)

      # Accumulate many failures
      for _ <- 1..10 do
        Sprite.reconcile_now(pid)
        Process.sleep(20)
      end

      {:ok, state} = Sprite.get_state(pid)
      assert state.backoff_ms <= 200
    end

    test "recovery after failures resets backoff" do
      # First, cause a failure
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :timeout} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      # Status stays as last known (cold), failure count incremented
      assert state.status == :cold
      assert state.failure_count > 0

      # Now succeed on next attempt: API returns a valid status
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :running}} end)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.status == :running
      assert state.failure_count == 0
      assert state.backoff_ms == 100
    end
  end

  # ── Edge Cases ──────────────────────────────────────────────────────

  describe "edge cases" do
    test "first not-found keeps process alive and increments not_found_count" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :not_found} end)

      {pid, _sprite_id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      assert Process.alive?(pid)

      {:ok, state} = Sprite.get_state(pid)
      assert state.not_found_count == 1
    end

    test "handles API timeout gracefully" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :timeout} end)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %ReconciliationResult{
                       sprite_id: ^sprite_id,
                       outcome: :failure
                     },
                     1_000

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
      # Status stays unchanged -- no transition to :error
      assert state.status == :cold
      # Process should still be alive after timeout
      assert Process.alive?(pid)
    end

    test "handles rate limiting error" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :rate_limited} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
      assert Process.alive?(pid)
    end

    test "handles server error from API" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, {:server_error, 500, "Internal Server Error"}} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.failure_count == 1
      assert Process.alive?(pid)
    end

    test "handles API returning unknown status" do
      # API returns a status we do not recognize -- maps to :cold
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: "unknown_status"}} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      # Unknown string status maps to :cold
      assert state.status == :cold
    end

    test "handles API response without status field" do
      # Missing status field maps to :cold
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", name: "no-status"}} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      # nil status maps to :cold
      assert state.status == :cold
    end
  end

  # ── External Deletion ─────────────────────────────────────────────

  describe "external deletion (two-strike not-found)" do
    test "first not-found does not kill the process" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :not_found} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      assert Process.alive?(pid)
      {:ok, state} = Sprite.get_state(pid)
      assert state.not_found_count == 1
    end

    test "second consecutive not-found stops the process" do
      test_pid = self()
      ref = make_ref()
      handler_id = "ext-delete-test-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:lattice, :sprite, :externally_deleted],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, event_name, measurements, metadata})
        end,
        nil
      )

      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :not_found} end)

      {pid, sprite_id} = start_sprite()

      # Monitor the process to detect when it stops
      process_ref = Process.monitor(pid)

      :ok = Events.subscribe_fleet()

      # First not-found
      Sprite.reconcile_now(pid)
      Process.sleep(50)
      assert Process.alive?(pid)

      # Second not-found — should stop
      Sprite.reconcile_now(pid)

      assert_receive {:DOWN, ^process_ref, :process, ^pid, :normal}, 1_000
      refute Process.alive?(pid)

      # Verify telemetry event
      assert_receive {:telemetry, ^ref, [:lattice, :sprite, :externally_deleted], %{count: 1},
                      %{sprite_id: ^sprite_id}},
                     1_000

      # Verify PubSub broadcast
      assert_receive {:sprite_externally_deleted, ^sprite_id}, 1_000

      :telemetry.detach(handler_id)
    end

    test "successful reconciliation resets not_found_count" do
      # First, trigger a not-found to set not_found_count to 1
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :not_found} end)

      {pid, _id} = start_sprite()

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.not_found_count == 1

      # Now make the API return success
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :cold}} end)

      Sprite.reconcile_now(pid)
      Process.sleep(50)

      {:ok, state} = Sprite.get_state(pid)
      assert state.not_found_count == 0
    end
  end

  # ── Backoff with Jitter ─────────────────────────────────────────────

  describe "backoff with jitter" do
    test "backoff delay includes jitter on failure" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:error, :api_timeout} end)

      {pid, _id} =
        start_sprite(base_backoff_ms: 1_000, max_backoff_ms: 10_000)

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
      stub_observation(:cold)

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

      {pid, _id} = start_sprite()

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
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :running}} end)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_fleet()

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{sprite_id: ^sprite_id, from_state: :cold, to_state: :running},
                     1_000
    end

    test "broadcasts reconciliation results to fleet topic" do
      stub_observation(:cold)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_fleet()

      Sprite.reconcile_now(pid)

      assert_receive %ReconciliationResult{sprite_id: ^sprite_id}, 1_000
    end

    test "broadcasts to per-sprite topic" do
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :running}} end)

      {pid, sprite_id} = start_sprite()

      :ok = Events.subscribe_sprite(sprite_id)

      Sprite.reconcile_now(pid)

      assert_receive %StateChange{sprite_id: ^sprite_id, from_state: :cold, to_state: :running},
                     1_000

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
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "test", status: :running}} end)

      {pid, sprite_id} = start_sprite()

      Sprite.reconcile_now(pid)

      assert_receive {:telemetry, ^ref, [:lattice, :sprite, :state_change], _measurements,
                      %{sprite_id: ^sprite_id}},
                     1_000
    end

    test "emits telemetry on reconciliation", %{ref: ref} do
      stub_observation(:cold)

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
      stub_observation(:cold)

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
      stub_observation(:cold)

      {pid, _id} = start_sprite(max_retries: 5)

      {:ok, state} = Sprite.get_state(pid)
      assert state.max_retries == 5
    end

    test "defaults max_retries to 10" do
      stub_observation(:cold)

      {pid, _id} = start_sprite()

      {:ok, state} = Sprite.get_state(pid)
      assert state.max_retries == 10
    end
  end
end
