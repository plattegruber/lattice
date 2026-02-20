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

  describe "handle_implementation/2 when disabled" do
    test "returns error when delegation is disabled" do
      Application.put_env(:lattice, SpriteDelegate, enabled: false)

      assert {:error, :delegation_disabled} = SpriteDelegate.handle_implementation(@event, [])
    end
  end

  describe "handle_implementation/2 full flow" do
    @impl_event %{
      type: :issue_comment,
      surface: :issue,
      number: 55,
      body: "implement this",
      title: "Add dark mode support",
      author: "contributor",
      comment_id: 200,
      repo: "org/repo"
    }

    setup do
      Application.put_env(:lattice, SpriteDelegate,
        enabled: true,
        sprite_name: "test-ambient",
        delegation_timeout_ms: 60_000,
        implementation_timeout_ms: 300_000
      )

      Application.put_env(:lattice, :resources, github_repo: "plattegruber/lattice")

      :ok
    end

    test "creates branch, runs claude, commits and pushes" do
      Lattice.Capabilities.MockSprites
      # ensure_sprite — sprite exists, pulls latest
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git pull"
        {:ok, %{output: "Already up to date.", exit_code: 0}}
      end)
      # create_and_checkout_branch
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git checkout main"
        assert cmd =~ "git checkout -b lattice/issue-55-add-dark-mode-support"
        {:ok, %{output: "Switched to new branch", exit_code: 0}}
      end)
      # run_implementation — write prompt
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "cat > /tmp/implement_prompt.txt"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # run_implementation — run claude
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "claude -p"
        assert cmd =~ "ANTHROPIC_API_KEY="
        {:ok, %{output: "Done implementing.", exit_code: 0}}
      end)
      # commit_and_push — git add
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git add -A"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # commit_and_push — git diff --cached --quiet (exit 1 = changes exist)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git diff --cached --quiet"
        {:ok, %{exit_code: 1, output: ""}}
      end)
      # commit_and_push — git commit
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git commit"
        assert cmd =~ "lattice: implement #55"
        {:ok, %{output: "1 file changed", exit_code: 0}}
      end)
      # commit_and_push — git push
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git push"
        assert cmd =~ "x-access-token"
        assert cmd =~ "lattice/issue-55-add-dark-mode-support"
        {:ok, %{output: "Branch pushed", exit_code: 0}}
      end)

      assert {:ok, branch} = SpriteDelegate.handle_implementation(@impl_event, [])
      assert branch == "lattice/issue-55-add-dark-mode-support"
    end

    test "returns :no_changes when git diff detects nothing staged" do
      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "Already up to date.", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "Switched to new branch", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "No changes needed.", exit_code: 0}}
      end)
      # git add -A
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "", exit_code: 0}}
      end)
      # git diff --cached --quiet — exit 0 means no changes
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{exit_code: 0, output: ""}}
      end)

      assert {:error, :no_changes} = SpriteDelegate.handle_implementation(@impl_event, [])
    end
  end
end
