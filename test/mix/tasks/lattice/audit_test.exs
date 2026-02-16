defmodule Mix.Tasks.Lattice.AuditTest do
  use ExUnit.Case

  @moduletag :unit

  import Mox

  alias Lattice.Capabilities.MockSprites
  alias Lattice.Sprites.FleetManager
  alias Mix.Tasks.Lattice.Audit

  setup :set_mox_global
  setup :verify_on_exit!

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp start_fleet_manager(sprite_configs) do
    sup_name = unique_name("audit_test_sup")
    fm_name = unique_name("audit_test_fm")

    original_config = Application.get_env(:lattice, :fleet, [])
    Application.put_env(:lattice, :fleet, sprites: sprite_configs)

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

    %{fm: fm_name}
  end

  defp cleanup_registry_sprites(sprite_ids) do
    Enum.each(sprite_ids, fn sprite_id ->
      case Registry.lookup(Lattice.Sprites.Registry, sprite_id) do
        [{pid, _}] when is_pid(pid) -> safe_stop(pid)
        _ -> :ok
      end
    end)
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

  describe "run_release/1" do
    test "completes audit and returns :ok for empty fleet" do
      %{fm: _fm} = start_fleet_manager([])

      assert :ok = Audit.run_release(timeout: 5_000)
    end

    test "completes audit with sprites present" do
      MockSprites
      |> stub(:get_sprite, fn _id ->
        {:ok, %{id: "audit-task-001", status: :hibernating}}
      end)

      %{fm: _fm} = start_fleet_manager([%{id: "audit-task-001", desired_state: :hibernating}])

      assert :ok = Audit.run_release(timeout: 5_000)
    end
  end
end
