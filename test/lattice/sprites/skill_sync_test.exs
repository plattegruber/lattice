defmodule Lattice.Sprites.SkillSyncTest do
  use ExUnit.Case
  @moduletag :unit

  import Mox

  alias Lattice.Sprites.SkillSync

  setup :set_mox_global
  setup :verify_on_exit!

  @test_skills [{"handoff/SKILL.md", "# Test Skill\nHello world"}]

  describe "sync_sprite/2" do
    test "clears directory, creates subdirs, writes files, and verifies" do
      Lattice.Capabilities.MockSprites
      # 1. rm -rf && mkdir -p (clear)
      |> expect(:exec, fn _name, cmd ->
        assert cmd =~ "rm -rf"
        assert cmd =~ "mkdir -p"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 2. mkdir -p for skill subdirs
      |> expect(:exec, fn _name, cmd ->
        assert cmd =~ "mkdir -p"
        assert cmd =~ "handoff"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 3. FileWriter: write first chunk
      |> expect(:exec, fn _name, cmd ->
        assert cmd =~ "> "
        assert cmd =~ ".b64"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 4. FileWriter: decode
      |> expect(:exec, fn _name, cmd ->
        assert cmd =~ "base64 -d"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # 5. ls -la verification
      |> expect(:exec, fn _name, cmd ->
        assert cmd =~ "ls -la"
        {:ok, %{output: "handoff/SKILL.md", exit_code: 0}}
      end)

      assert :ok = SkillSync.sync_sprite("test-sprite", @test_skills)
    end

    test "returns error when clear fails" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn _name, _cmd ->
        {:error, :not_found}
      end)

      assert {:error, :not_found} = SkillSync.sync_sprite("missing-sprite", @test_skills)
    end

    test "returns error when file write fails" do
      Lattice.Capabilities.MockSprites
      # clear succeeds
      |> expect(:exec, fn _name, _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      # mkdir succeeds
      |> expect(:exec, fn _name, _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      # file write fails (non-retryable error)
      |> expect(:exec, fn _name, _cmd -> {:error, :write_failed} end)

      assert {:error, :write_failed} = SkillSync.sync_sprite("test-sprite", @test_skills)
    end
  end

  describe "sync_all/0" do
    test "syncs skills to all discovered sprites" do
      Lattice.Capabilities.MockSprites
      # list_sprites
      |> expect(:list_sprites, fn ->
        {:ok, [%{id: "sprite-1", name: "sprite-1"}, %{id: "sprite-2", name: "sprite-2"}]}
      end)
      # Each sprite gets 5 exec calls (clear, mkdir, write chunk, decode, verify)
      |> expect(:exec, 10, fn _name, _cmd ->
        {:ok, %{output: "", exit_code: 0}}
      end)

      results = SkillSync.sync_all()
      assert results["sprite-1"] == :ok
      assert results["sprite-2"] == :ok
    end

    test "returns empty map when list_sprites fails" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn -> {:error, :api_error} end)

      assert %{} = SkillSync.sync_all()
    end

    test "handles partial failures gracefully" do
      Lattice.Capabilities.MockSprites
      |> expect(:list_sprites, fn ->
        {:ok, [%{id: "ok-sprite", name: "ok-sprite"}, %{id: "bad-sprite", name: "bad-sprite"}]}
      end)
      # ok-sprite: all 5 calls succeed
      |> expect(:exec, 5, fn "ok-sprite", _cmd ->
        {:ok, %{output: "", exit_code: 0}}
      end)
      # bad-sprite: clear fails (non-retryable)
      |> expect(:exec, fn "bad-sprite", _cmd ->
        {:error, :sprite_unavailable}
      end)

      results = SkillSync.sync_all()
      assert results["ok-sprite"] == :ok
      assert {:error, :sprite_unavailable} = results["bad-sprite"]
    end
  end

  describe "discover_skills/0" do
    test "finds skills in priv/sprite_skills" do
      skills = SkillSync.discover_skills()
      assert skills != []

      {path, content} = Enum.find(skills, fn {p, _} -> p == "handoff/SKILL.md" end)
      assert path == "handoff/SKILL.md"
      assert content =~ "LatticeBundleHandoff"
    end
  end
end
