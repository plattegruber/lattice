defmodule Mix.Tasks.Lattice.CronTest do
  use ExUnit.Case

  @moduletag :unit

  import Mox

  alias Lattice.Capabilities.MockSprites
  alias Lattice.Sprites.FleetManager
  alias Mix.Tasks.Lattice.Cron

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    original = Application.get_env(:lattice, Lattice.Ambient.SpriteDelegate)

    on_exit(fn ->
      if original do
        Application.put_env(:lattice, Lattice.Ambient.SpriteDelegate, original)
      else
        Application.delete_env(:lattice, Lattice.Ambient.SpriteDelegate)
      end
    end)

    # Default: no credential source configured
    Application.put_env(:lattice, Lattice.Ambient.SpriteDelegate, [])

    :ok
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp start_fleet_manager(sprite_configs) do
    sup_name = unique_name("cron_test_sup")
    fm_name = unique_name("cron_test_fm")

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

  describe "run_release/0" do
    test "completes all steps for empty fleet" do
      MockSprites
      |> stub(:list_sprites, fn -> {:ok, []} end)

      %{fm: _fm} = start_fleet_manager([])

      assert :ok = Cron.run_release()
    end

    test "handles partial failures — still runs all steps even if one fails" do
      # Skill sync will fail because exec fails for the sprite.
      # Fleet audit and credential sync should still complete.
      MockSprites
      |> stub(:list_sprites, fn ->
        {:ok, [%{id: "failing-sprite", name: "failing-sprite"}]}
      end)
      |> stub(:exec, fn _name, _cmd -> {:error, :unavailable} end)

      %{fm: _fm} = start_fleet_manager([])

      # Skill sync fails → cron exits with code 1
      assert catch_exit(Cron.run_release()) == {:shutdown, 1}
    end
  end
end
