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

  # A minimal GenServer that mimics ExecSession for testing.
  # Instead of using PubSub (which may be unstable in test env),
  # it sends exec_output messages directly to the caller process
  # after the caller subscribes to the PubSub topic.
  defmodule FakeSession do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      session_id = "test_exec_#{System.unique_integer([:positive])}"
      output = Keyword.get(opts, :output, "")
      exit_code = Keyword.get(opts, :exit_code, 0)
      caller = Keyword.get(opts, :caller)

      # Schedule the output delivery
      send(self(), {:deliver_output, session_id, output, exit_code, caller})

      {:ok, %{session_id: session_id}}
    end

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply, {:ok, state}, state}
    end

    @impl true
    def handle_info({:deliver_output, session_id, output, exit_code, caller}, state) do
      # Wait for the caller to subscribe to PubSub and enter collect_loop
      Process.sleep(50)

      # Send messages directly to the caller process, matching the format
      # that Phoenix.PubSub would deliver
      if output != "" do
        send(
          caller,
          {:exec_output,
           %{
             session_id: session_id,
             sprite_id: "test",
             stream: :stdout,
             chunk: output,
             timestamp: DateTime.utc_now()
           }}
        )
      end

      Process.sleep(5)

      send(
        caller,
        {:exec_output,
         %{
           session_id: session_id,
           sprite_id: "test",
           stream: :exit,
           chunk: "Process exited with code #{exit_code}",
           timestamp: DateTime.utc_now()
         }}
      )

      {:noreply, state}
    end
  end

  defp start_fake_session(output, exit_code \\ 0) do
    {:ok, pid} = FakeSession.start_link(output: output, exit_code: exit_code, caller: self())
    pid
  end

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
        sprite_name: "test-ambient"
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
      # write_prompt_file: write b64, then decode
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "printf"
        assert cmd =~ "ambient_prompt.txt.b64"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "base64 -d"
        assert cmd =~ "ambient_prompt.txt"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec_ws, fn "test-ambient", cmd, _opts ->
        assert cmd =~ "claude -p"
        {:ok, start_fake_session("The fleet manager uses a DynamicSupervisor.")}
      end)

      assert {:ok, response} = SpriteDelegate.handle(@event, [])
      assert response =~ "DynamicSupervisor"
    end

    test "includes thread context in prompt" do
      thread = [%{user: "alice", body: "I'm curious about this too"}]

      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      # write_prompt_file: write b64, then decode
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "printf"
        assert cmd =~ "ambient_prompt.txt.b64"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "base64 -d"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec_ws, fn "test-ambient", _cmd, _opts ->
        {:ok, start_fake_session("Here's the answer with context.")}
      end)

      assert {:ok, _} = SpriteDelegate.handle(@event, thread)
    end
  end

  describe "handle/2 when sprite needs creation" do
    setup do
      Application.put_env(:lattice, SpriteDelegate,
        enabled: true,
        sprite_name: "new-ambient"
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
      # write_prompt_file: write b64, then decode
      |> expect(:exec, fn "new-ambient", cmd ->
        assert cmd =~ "printf"
        assert cmd =~ "ambient_prompt.txt.b64"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn "new-ambient", cmd ->
        assert cmd =~ "base64 -d"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec_ws, fn "new-ambient", cmd, _opts ->
        assert cmd =~ "claude -p"
        {:ok, start_fake_session("Fleet manager explained.")}
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
        sprite_name: "test-ambient"
      )

      Application.put_env(:lattice, :resources, github_repo: "plattegruber/lattice")

      :ok
    end

    test "returns error on empty claude response" do
      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      # write_prompt_file: write b64, then decode
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec_ws, fn "test-ambient", _cmd, _opts ->
        {:ok, start_fake_session("   \n  ")}
      end)

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
        sprite_name: "test-ambient"
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
      # write_prompt_file: write b64, then decode
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "printf"
        assert cmd =~ "implement_prompt.txt.b64"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "base64 -d"
        assert cmd =~ "implement_prompt.txt"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # run_implementation — run claude via streaming exec
      |> expect(:exec_ws, fn "test-ambient", cmd, _opts ->
        assert cmd =~ "claude -p"
        assert cmd =~ "ANTHROPIC_API_KEY="
        {:ok, start_fake_session("Done implementing.")}
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
      # write_prompt_file: write b64, then decode
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec_ws, fn "test-ambient", _cmd, _opts ->
        {:ok, start_fake_session("No changes needed.")}
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
