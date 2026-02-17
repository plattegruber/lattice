defmodule Lattice.Sprites.FleetManagerTest do
  use ExUnit.Case

  @moduletag :unit

  import Mox

  alias Lattice.Events
  alias Lattice.Sprites.FleetManager
  alias Lattice.Sprites.Sprite
  alias Lattice.Sprites.State

  # Mox requires verify_on_exit! for each test.
  # set_mox_global allows stubs to be called from any process (the GenServer).
  setup :set_mox_global
  setup :verify_on_exit!

  # Default: API discovery fails, so FleetManager falls back to static config.
  # Tests that want API discovery can override this stub before calling start_fleet_manager.
  setup do
    Lattice.Capabilities.MockSprites
    |> Mox.stub(:list_sprites, fn -> {:error, :not_configured} end)

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp start_fleet_manager(sprite_configs, opts \\ []) do
    sup_name = Keyword.get(opts, :supervisor, unique_name("test_sup"))
    fm_name = Keyword.get(opts, :name, unique_name("test_fm"))

    # Temporarily set the fleet config
    original_config = Application.get_env(:lattice, :fleet, [])
    Application.put_env(:lattice, :fleet, sprites: sprite_configs)

    # Start a dedicated DynamicSupervisor for this test
    {:ok, _sup_pid} = DynamicSupervisor.start_link(name: sup_name, strategy: :one_for_one)

    {:ok, fm_pid} = FleetManager.start_link(name: fm_name, supervisor: sup_name)

    # Allow the :continue callback to finish
    Process.sleep(50)

    sprite_ids = Enum.map(sprite_configs, & &1.id)

    on_exit(fn ->
      Application.put_env(:lattice, :fleet, original_config)
      safe_stop(fm_pid)
      safe_stop_named(sup_name)
      cleanup_registry_sprites(sprite_ids)
    end)

    %{fm: fm_name, sup: sup_name}
  end

  defp cleanup_registry_sprites(sprite_ids) do
    Enum.each(sprite_ids, &stop_registered_sprite/1)
  end

  defp stop_registered_sprite(sprite_id) do
    case Registry.lookup(Lattice.Sprites.Registry, sprite_id) do
      [{pid, _}] when is_pid(pid) -> safe_stop(pid)
      _ -> :ok
    end
  end

  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  defp safe_stop(_), do: :ok

  defp safe_stop_named(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> safe_stop(pid)
    end
  end

  # ── Discovery & Startup ────────────────────────────────────────────

  describe "sprite discovery and startup" do
    test "starts with no sprites when config is empty" do
      %{fm: fm} = start_fleet_manager([])

      assert FleetManager.list_sprites(fm) == []
    end

    test "starts configured sprites" do
      configs = [
        %{id: "fleet-test-001", desired_state: :hibernating},
        %{id: "fleet-test-002", desired_state: :hibernating}
      ]

      %{fm: fm} = start_fleet_manager(configs)

      sprites = FleetManager.list_sprites(fm)
      ids = Enum.map(sprites, fn {id, _state} -> id end)

      assert length(sprites) == 2
      assert "fleet-test-001" in ids
      assert "fleet-test-002" in ids
    end

    test "started sprites are registered in the Registry" do
      configs = [%{id: "fleet-reg-001", desired_state: :hibernating}]

      %{fm: _fm} = start_fleet_manager(configs)

      assert {:ok, pid} = FleetManager.get_sprite_pid("fleet-reg-001")
      assert Process.alive?(pid)
    end

    test "started sprites respect desired_state from config" do
      configs = [%{id: "fleet-desired-001", desired_state: :ready}]

      %{fm: fm} = start_fleet_manager(configs)

      [{_id, state}] = FleetManager.list_sprites(fm)
      assert state.desired_state == :ready
    end

    test "started sprites default to hibernating desired state" do
      configs = [%{id: "fleet-default-001"}]

      %{fm: fm} = start_fleet_manager(configs)

      [{_id, state}] = FleetManager.list_sprites(fm)
      assert state.desired_state == :hibernating
    end
  end

  # ── API Discovery ────────────────────────────────────────────────

  describe "API sprite discovery" do
    test "discovers sprites from API at boot" do
      Lattice.Capabilities.MockSprites
      |> Mox.stub(:list_sprites, fn ->
        {:ok, [%{id: "api-sprite-001"}, %{id: "api-sprite-002"}]}
      end)

      %{fm: fm} = start_fleet_manager([])

      sprites = FleetManager.list_sprites(fm)
      ids = Enum.map(sprites, fn {id, _state} -> id end)

      assert length(sprites) == 2
      assert "api-sprite-001" in ids
      assert "api-sprite-002" in ids
    end

    test "falls back to static config when API fails" do
      Lattice.Capabilities.MockSprites
      |> Mox.stub(:list_sprites, fn -> {:error, :connection_refused} end)

      configs = [%{id: "fallback-001", desired_state: :hibernating}]
      %{fm: fm} = start_fleet_manager(configs)

      sprites = FleetManager.list_sprites(fm)
      ids = Enum.map(sprites, fn {id, _state} -> id end)

      assert length(sprites) == 1
      assert "fallback-001" in ids
    end
  end

  # ── Fleet Queries ──────────────────────────────────────────────────

  describe "list_sprites/1" do
    test "returns sprite IDs with their current state" do
      configs = [%{id: "fleet-list-001", desired_state: :hibernating}]

      %{fm: fm} = start_fleet_manager(configs)

      sprites = FleetManager.list_sprites(fm)
      assert [{id, %State{}}] = sprites
      assert id == "fleet-list-001"
    end
  end

  describe "get_sprite_pid/1" do
    test "returns {:ok, pid} for a known sprite" do
      configs = [%{id: "fleet-pid-001", desired_state: :hibernating}]
      start_fleet_manager(configs)

      assert {:ok, pid} = FleetManager.get_sprite_pid("fleet-pid-001")
      assert is_pid(pid)
    end

    test "returns {:error, :not_found} for unknown sprite" do
      start_fleet_manager([])

      assert {:error, :not_found} = FleetManager.get_sprite_pid("nonexistent")
    end
  end

  describe "fleet_summary/1" do
    test "returns total count and breakdown by state" do
      configs = [
        %{id: "fleet-sum-001", desired_state: :hibernating},
        %{id: "fleet-sum-002", desired_state: :hibernating}
      ]

      %{fm: fm} = start_fleet_manager(configs)

      summary = FleetManager.fleet_summary(fm)
      assert summary.total == 2
      assert summary.by_state[:hibernating] == 2
    end

    test "returns zeros when fleet is empty" do
      %{fm: fm} = start_fleet_manager([])

      summary = FleetManager.fleet_summary(fm)
      assert summary.total == 0
      assert summary.by_state == %{}
    end
  end

  # ── Fleet-Wide Operations ──────────────────────────────────────────

  describe "wake_sprites/2" do
    test "sets desired state to ready for specified sprites" do
      configs = [
        %{id: "fleet-wake-001", desired_state: :hibernating},
        %{id: "fleet-wake-002", desired_state: :hibernating}
      ]

      %{fm: fm} = start_fleet_manager(configs)

      results = FleetManager.wake_sprites(["fleet-wake-001"], fm)
      assert results["fleet-wake-001"] == :ok

      [{_id, state}] =
        FleetManager.list_sprites(fm)
        |> Enum.filter(fn {id, _} -> id == "fleet-wake-001" end)

      assert state.desired_state == :ready
    end

    test "returns error for unknown sprite IDs" do
      %{fm: fm} = start_fleet_manager([])

      results = FleetManager.wake_sprites(["unknown-001"], fm)
      assert results["unknown-001"] == {:error, :not_found}
    end
  end

  describe "sleep_sprites/2" do
    test "sets desired state to hibernating for specified sprites" do
      configs = [%{id: "fleet-sleep-001", desired_state: :hibernating}]

      %{fm: fm} = start_fleet_manager(configs)

      # First wake the sprite
      FleetManager.wake_sprites(["fleet-sleep-001"], fm)

      # Then sleep it
      results = FleetManager.sleep_sprites(["fleet-sleep-001"], fm)
      assert results["fleet-sleep-001"] == :ok

      [{_id, state}] = FleetManager.list_sprites(fm)
      assert state.desired_state == :hibernating
    end
  end

  describe "run_audit/1" do
    test "triggers reconciliation on all sprites" do
      # Stub get_sprite since reconciliation now fetches real API state
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "fleet-audit-001", status: :hibernating}} end)

      configs = [%{id: "fleet-audit-001", desired_state: :hibernating}]

      %{fm: fm} = start_fleet_manager(configs)

      :ok = Events.subscribe_sprite("fleet-audit-001")

      assert :ok = FleetManager.run_audit(fm)

      # Should receive a reconciliation result
      assert_receive %Lattice.Events.ReconciliationResult{
                       sprite_id: "fleet-audit-001"
                     },
                     1_000
    end
  end

  # ── PubSub Broadcasting ────────────────────────────────────────────

  describe "fleet summary broadcasting" do
    test "broadcasts fleet summary on wake_sprites" do
      configs = [%{id: "fleet-bc-001", desired_state: :hibernating}]

      %{fm: fm} = start_fleet_manager(configs)

      :ok = Events.subscribe_fleet()

      FleetManager.wake_sprites(["fleet-bc-001"], fm)

      assert_receive {:fleet_summary, %{total: 1}}, 1_000
    end

    test "broadcasts fleet summary on sleep_sprites" do
      configs = [%{id: "fleet-bc-002", desired_state: :hibernating}]

      %{fm: fm} = start_fleet_manager(configs)

      :ok = Events.subscribe_fleet()

      FleetManager.sleep_sprites(["fleet-bc-002"], fm)

      assert_receive {:fleet_summary, %{total: 1}}, 1_000
    end

    test "broadcasts fleet summary on run_audit" do
      # Stub get_sprite since reconciliation now fetches real API state
      Lattice.Capabilities.MockSprites
      |> stub(:get_sprite, fn _id -> {:ok, %{id: "fleet-bc-003", status: :hibernating}} end)

      configs = [%{id: "fleet-bc-003", desired_state: :hibernating}]

      %{fm: fm} = start_fleet_manager(configs)

      :ok = Events.subscribe_fleet()

      FleetManager.run_audit(fm)

      assert_receive {:fleet_summary, %{total: 1}}, 1_000
    end

    test "broadcasts fleet summary after initial discovery" do
      :ok = Events.subscribe_fleet()

      configs = [%{id: "fleet-bc-004", desired_state: :hibernating}]
      start_fleet_manager(configs)

      assert_receive {:fleet_summary, %{total: 1}}, 1_000
    end
  end

  # ── Telemetry ──────────────────────────────────────────────────────

  describe "telemetry events" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "fleet-manager-test-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:lattice, :fleet, :summary],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{ref: ref}
    end

    test "emits fleet summary telemetry on discovery", %{ref: ref} do
      configs = [%{id: "fleet-tel-001", desired_state: :hibernating}]
      start_fleet_manager(configs)

      assert_receive {:telemetry, ^ref, [:lattice, :fleet, :summary], %{total: 1}, _metadata},
                     1_000
    end
  end

  # ── add_sprite/3 ──────────────────────────────────────────────────

  describe "add_sprite/3" do
    test "adds a new sprite to the fleet at runtime" do
      %{fm: fm} = start_fleet_manager([])

      assert {:ok, "runtime-sprite-001"} = FleetManager.add_sprite("runtime-sprite-001", [], fm)

      sprites = FleetManager.list_sprites(fm)
      ids = Enum.map(sprites, fn {id, _state} -> id end)
      assert "runtime-sprite-001" in ids
    end

    test "new sprite is reachable via Registry" do
      %{fm: fm} = start_fleet_manager([])

      {:ok, "runtime-reg-001"} = FleetManager.add_sprite("runtime-reg-001", [], fm)

      assert {:ok, pid} = FleetManager.get_sprite_pid("runtime-reg-001")
      assert Process.alive?(pid)
    end

    test "returns error for duplicate sprite" do
      configs = [%{id: "runtime-dup-001", desired_state: :hibernating}]
      %{fm: fm} = start_fleet_manager(configs)

      assert {:error, :already_exists} = FleetManager.add_sprite("runtime-dup-001", [], fm)
    end

    test "broadcasts fleet summary after adding sprite" do
      %{fm: fm} = start_fleet_manager([])

      :ok = Events.subscribe_fleet()

      FleetManager.add_sprite("runtime-bc-001", [], fm)

      assert_receive {:fleet_summary, %{total: 1}}, 1_000
    end

    test "new sprite appears in fleet_summary" do
      %{fm: fm} = start_fleet_manager([])

      FleetManager.add_sprite("runtime-sum-001", [], fm)

      summary = FleetManager.fleet_summary(fm)
      assert summary.total == 1
      assert summary.by_state[:hibernating] == 1
    end

    test "respects desired_state option" do
      %{fm: fm} = start_fleet_manager([])

      {:ok, "runtime-ds-001"} =
        FleetManager.add_sprite("runtime-ds-001", [desired_state: :ready], fm)

      [{_id, state}] =
        FleetManager.list_sprites(fm)
        |> Enum.filter(fn {id, _} -> id == "runtime-ds-001" end)

      assert state.desired_state == :ready
    end
  end

  # ── Sprite via Registry ────────────────────────────────────────────

  describe "Sprite.via/1 integration" do
    test "sprite can be reached via Registry name" do
      configs = [%{id: "fleet-via-001", desired_state: :hibernating}]
      start_fleet_manager(configs)

      via = Sprite.via("fleet-via-001")
      {:ok, state} = Sprite.get_state(via)
      assert %State{} = state
      assert state.sprite_id == "fleet-via-001"
    end
  end
end
