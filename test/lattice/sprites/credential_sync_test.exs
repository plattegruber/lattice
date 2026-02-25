defmodule Lattice.Sprites.CredentialSyncTest do
  use ExUnit.Case
  @moduletag :unit

  import Mox

  alias Lattice.Sprites.CredentialSync

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

    :ok
  end

  describe "sync_all/0" do
    test "returns empty map when no source sprite configured" do
      Application.put_env(:lattice, Lattice.Ambient.SpriteDelegate, [])

      assert %{} = CredentialSync.sync_all()
    end

    test "reads once from source and fans out writes to all other sprites" do
      Application.put_env(:lattice, Lattice.Ambient.SpriteDelegate,
        credentials_source_sprite: "source-sprite"
      )

      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn ->
        {:ok,
         [
           %{id: "source-sprite", name: "source-sprite"},
           %{id: "target-1", name: "target-1"},
           %{id: "target-2", name: "target-2"}
         ]}
      end)
      # read credentials from source (once)
      |> expect(:exec, fn "source-sprite", cmd ->
        assert cmd =~ "cat /home/sprite/.claude/.credentials.json"
        {:ok, %{exit_code: 0, output: ~s({"token":"abc123"})}}
      end)
      # write to target-1
      |> expect(:exec, fn "target-1", cmd ->
        assert cmd =~ "mkdir -p /home/sprite/.claude"
        assert cmd =~ "credentials.json"
        {:ok, %{exit_code: 0, output: ""}}
      end)
      # write to target-2
      |> expect(:exec, fn "target-2", cmd ->
        assert cmd =~ "mkdir -p /home/sprite/.claude"
        {:ok, %{exit_code: 0, output: ""}}
      end)

      results = CredentialSync.sync_all()
      assert results["target-1"] == :ok
      assert results["target-2"] == :ok
      refute Map.has_key?(results, "source-sprite")
    end

    test "returns empty map when read from source fails" do
      Application.put_env(:lattice, Lattice.Ambient.SpriteDelegate,
        credentials_source_sprite: "source-sprite"
      )

      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn ->
        {:ok, [%{id: "source-sprite", name: "source-sprite"}, %{id: "target", name: "target"}]}
      end)
      |> expect(:exec, fn "source-sprite", _cmd ->
        {:ok, %{exit_code: 1, output: ""}}
      end)

      assert %{} = CredentialSync.sync_all()
    end

    test "returns empty map when list_sprites fails" do
      Application.put_env(:lattice, Lattice.Ambient.SpriteDelegate,
        credentials_source_sprite: "source-sprite"
      )

      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:error, :api_error} end)

      assert %{} = CredentialSync.sync_all()
    end
  end

  describe "sync_one/2" do
    test "no-op when source == target" do
      assert :ok = CredentialSync.sync_one("same", "same")
    end

    test "reads from source and writes to target" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "source", cmd ->
        assert cmd =~ "cat /home/sprite/.claude/.credentials.json"
        {:ok, %{exit_code: 0, output: ~s({"token":"xyz"})}}
      end)
      |> expect(:exec, fn "target", cmd ->
        assert cmd =~ "mkdir -p /home/sprite/.claude"
        assert cmd =~ "chmod 600"
        {:ok, %{exit_code: 0, output: ""}}
      end)

      assert :ok = CredentialSync.sync_one("source", "target")
    end

    test "returns error when read fails" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "source", _cmd ->
        {:error, :not_found}
      end)

      assert {:error, :credentials_read_failed} = CredentialSync.sync_one("source", "target")
    end

    test "returns error when write fails" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "source", _cmd ->
        {:ok, %{exit_code: 0, output: ~s({"token":"xyz"})}}
      end)
      |> expect(:exec, fn "target", _cmd ->
        {:ok, %{exit_code: 1, output: "permission denied"}}
      end)

      assert {:error, :credentials_write_failed} = CredentialSync.sync_one("source", "target")
    end
  end
end
