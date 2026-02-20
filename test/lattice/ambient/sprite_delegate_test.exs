defmodule Lattice.Ambient.SpriteDelegateTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  import Mox

  alias Lattice.Ambient.SpriteDelegate

  setup :verify_on_exit!

  setup do
    # Store original config and restore after test
    original = Application.get_env(:lattice, SpriteDelegate)

    on_exit(fn ->
      if original do
        Application.put_env(:lattice, SpriteDelegate, original)
      else
        Application.delete_env(:lattice, SpriteDelegate)
      end
    end)

    :ok
  end

  @event %{
    type: :issue_comment,
    surface: :issue,
    number: 42,
    body: "How does the fleet manager work?",
    title: "Architecture question",
    author: "curious-dev",
    comment_id: 100,
    repo: "org/repo"
  }

  describe "handle/2 when disabled" do
    test "returns error when delegation is disabled" do
      Application.put_env(:lattice, SpriteDelegate, enabled: false)

      assert {:error, :delegation_disabled} = SpriteDelegate.handle(@event, [])
    end
  end

  describe "handle/2 when enabled with existing sprite" do
    setup do
      Application.put_env(:lattice, SpriteDelegate,
        enabled: true,
        sprite_name: "test-ambient",
        delegation_timeout_ms: 60_000
      )

      Application.put_env(:lattice, :resources, github_repo: "plattegruber/lattice")

      :ok
    end

    test "reuses existing sprite and runs claude code" do
      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git pull"
        {:ok, %{output: "Already up to date.", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "cat > /tmp/ambient_prompt.txt"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "claude -p"
        {:ok, %{output: "The fleet manager uses a DynamicSupervisor.", exit_code: 0}}
      end)

      assert {:ok, response} = SpriteDelegate.handle(@event, [])
      assert response =~ "DynamicSupervisor"
    end

    test "includes thread context in prompt" do
      thread = [%{user: "alice", body: "I'm curious about this too"}]

      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "cat > /tmp/ambient_prompt.txt"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "Here's the answer with context.", exit_code: 0}}
      end)

      assert {:ok, _} = SpriteDelegate.handle(@event, thread)
    end
  end

  describe "handle/2 when sprite needs creation" do
    setup do
      Application.put_env(:lattice, SpriteDelegate,
        enabled: true,
        sprite_name: "new-ambient",
        delegation_timeout_ms: 60_000
      )

      Application.put_env(:lattice, :resources, github_repo: "plattegruber/lattice")

      :ok
    end

    test "creates sprite and clones repo when not found" do
      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "new-ambient" -> {:error, :not_found} end)
      |> expect(:create_sprite, fn "new-ambient", [] -> {:ok, %{name: "new-ambient"}} end)
      |> expect(:exec, fn "new-ambient", cmd ->
        assert cmd =~ "git clone"
        assert cmd =~ "plattegruber/lattice"
        {:ok, %{output: "Cloning into...", exit_code: 0}}
      end)
      |> expect(:exec, fn "new-ambient", cmd ->
        assert cmd =~ "cat > /tmp/ambient_prompt.txt"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn "new-ambient", cmd ->
        assert cmd =~ "claude -p"
        {:ok, %{output: "Fleet manager explained.", exit_code: 0}}
      end)

      assert {:ok, "Fleet manager explained."} = SpriteDelegate.handle(@event, [])
    end

    test "returns error when sprite creation fails" do
      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "new-ambient" -> {:error, :not_found} end)
      |> expect(:create_sprite, fn "new-ambient", [] -> {:error, :quota_exceeded} end)

      assert {:error, :quota_exceeded} = SpriteDelegate.handle(@event, [])
    end
  end

  describe "handle/2 when claude returns empty response" do
    setup do
      Application.put_env(:lattice, SpriteDelegate,
        enabled: true,
        sprite_name: "test-ambient",
        delegation_timeout_ms: 60_000
      )

      Application.put_env(:lattice, :resources, github_repo: "plattegruber/lattice")

      :ok
    end

    test "returns error on empty claude response" do
      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "   \n  ", exit_code: 0}} end)

      assert {:error, :empty_response} = SpriteDelegate.handle(@event, [])
    end
  end
end
