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
      # sanity check
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "SANITY"
        {:ok, %{output: "--- SANITY OK ---", exit_code: 0}}
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
      # sanity check
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "--- SANITY OK ---", exit_code: 0}}
      end)
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
      # sanity check
      |> expect(:exec, fn "new-ambient", _cmd ->
        {:ok, %{output: "--- SANITY OK ---", exit_code: 0}}
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
      # sanity check
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "--- SANITY OK ---", exit_code: 0}}
      end)
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

    @valid_proposal_json Jason.encode!(%{
                           "protocol_version" => "bundle-v1",
                           "status" => "ready",
                           "repo" => "plattegruber/lattice",
                           "base_branch" => "main",
                           "work_branch" => "sprite/add-dark-mode-support",
                           "bundle_path" => ".lattice/out/change.bundle",
                           "patch_path" => ".lattice/out/diff.patch",
                           "summary" => "Added dark mode support",
                           "pr" => %{
                             "title" => "Add dark mode support",
                             "body" => "Implements dark mode theming",
                             "labels" => ["lattice:ambient"],
                             "review_notes" => []
                           },
                           "commands" => [
                             %{"cmd" => "mix format", "exit" => 0},
                             %{"cmd" => "mix test", "exit" => 0}
                           ],
                           "flags" => %{
                             "touches_migrations" => false,
                             "touches_deps" => false,
                             "touches_auth" => false,
                             "touches_secrets" => false
                           }
                         })

    setup do
      Application.put_env(:lattice, SpriteDelegate,
        enabled: true,
        sprite_name: "test-ambient"
      )

      Application.put_env(:lattice, :resources, github_repo: "plattegruber/lattice")

      :ok
    end

    test "full handoff flow: prepare, run, read proposal, validate, verify, push" do
      Lattice.Capabilities.MockSprites
      # ensure_sprite — sprite exists, pulls latest
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git pull"
        {:ok, %{output: "Already up to date.", exit_code: 0}}
      end)
      # prepare_workspace — git checkout -f main && git clean -fd && git pull
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git checkout -f main"
        assert cmd =~ "git clean -fd"
        assert cmd =~ "git pull"
        {:ok, %{output: "Already on main", exit_code: 0}}
      end)
      # prepare_workspace — rm -rf .lattice/out && mkdir
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "rm -rf .lattice/out"
        assert cmd =~ "mkdir -p .lattice/out"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # sanity check
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "--- SANITY OK ---", exit_code: 0}}
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
      # run_implementation — claude -p via streaming exec
      |> expect(:exec_ws, fn "test-ambient", cmd, _opts ->
        assert cmd =~ "claude -p"
        assert cmd =~ "ANTHROPIC_API_KEY="
        {:ok, start_fake_session("HANDOFF_READY: .lattice/out/")}
      end)
      # read_proposal — cat proposal.json
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "proposal.json"
        {:ok, %{output: @valid_proposal_json, exit_code: 0}}
      end)
      # validate_proposal — git diff --name-only
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git diff --name-only"
        {:ok, %{output: "lib/lattice/theme.ex\ntest/lattice/theme_test.exs", exit_code: 0}}
      end)
      # verify_bundle — git bundle verify
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git bundle verify"
        {:ok, %{output: "The bundle is valid.", exit_code: 0}}
      end)
      # push_bundle — git fetch bundle (uses HEAD ref, not branch name)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git fetch"
        assert cmd =~ "change.bundle"
        assert cmd =~ "HEAD:refs/heads/"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # push_bundle — git push
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git push"
        assert cmd =~ "x-access-token"
        assert cmd =~ "lattice/issue-55-add-dark-mode-support"
        {:ok, %{output: "Branch pushed", exit_code: 0}}
      end)

      assert {:ok, result} = SpriteDelegate.handle_implementation(@impl_event, [])
      assert result.branch == "lattice/issue-55-add-dark-mode-support"
      assert result.proposal.status == "ready"
      assert result.proposal.pr["title"] == "Add dark mode support"
      assert result.warnings == []
    end

    test "returns :no_changes when proposal status is no_changes" do
      no_changes_json =
        Jason.encode!(%{
          "protocol_version" => "bundle-v1",
          "status" => "no_changes",
          "base_branch" => "main",
          "work_branch" => "sprite/add-dark-mode-support",
          "bundle_path" => ".lattice/out/change.bundle"
        })

      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "Already up to date.", exit_code: 0}}
      end)
      # prepare_workspace
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "Already on main", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      # sanity check
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "--- SANITY OK ---", exit_code: 0}}
      end)
      # write_prompt_file
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec_ws, fn "test-ambient", _cmd, _opts ->
        {:ok, start_fake_session("HANDOFF_READY: .lattice/out/")}
      end)
      # read_proposal
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: no_changes_json, exit_code: 0}}
      end)

      assert {:error, :no_changes} = SpriteDelegate.handle_implementation(@impl_event, [])
    end

    test "returns :no_proposal when proposal.json is missing" do
      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "Already up to date.", exit_code: 0}}
      end)
      # prepare_workspace
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "Already on main", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      # sanity check
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "--- SANITY OK ---", exit_code: 0}}
      end)
      # write_prompt_file
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec_ws, fn "test-ambient", _cmd, _opts ->
        {:ok, start_fake_session("Done but no proposal.")}
      end)
      # read_proposal — file not found
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "", exit_code: 1}}
      end)

      assert {:error, :no_proposal} = SpriteDelegate.handle_implementation(@impl_event, [])
    end

    test "amendment flow: detects PR, checks out head branch, pushes with force-with-lease" do
      pr_event = %{
        type: :issue_comment,
        surface: :pr_comment,
        number: 203,
        body: "Fix these changes and commit them to our branch",
        title: "Fix tests",
        author: "reviewer",
        comment_id: 700,
        repo: "org/repo",
        is_pull_request: true
      }

      amendment_proposal_json =
        Jason.encode!(%{
          "protocol_version" => "bundle-v1",
          "status" => "ready",
          "repo" => "plattegruber/lattice",
          "base_branch" => "main",
          "work_branch" => "feature/fix-tests",
          "bundle_path" => ".lattice/out/change.bundle",
          "patch_path" => ".lattice/out/diff.patch",
          "summary" => "Fixed the test failures",
          "pr" => %{
            "title" => "Amendment for PR #203",
            "body" => "Fixed failing tests",
            "labels" => ["lattice:ambient"],
            "review_notes" => []
          },
          "commands" => [
            %{"cmd" => "mix format", "exit" => 0},
            %{"cmd" => "mix test", "exit" => 0}
          ],
          "flags" => %{
            "touches_migrations" => false,
            "touches_deps" => false,
            "touches_auth" => false,
            "touches_secrets" => false
          }
        })

      Lattice.Capabilities.MockGitHub
      |> expect(:get_pull_request, fn 203 ->
        {:ok, %{number: 203, head: %{ref: "feature/fix-tests"}, base: %{ref: "main"}}}
      end)

      Lattice.Capabilities.MockSprites
      # ensure_sprite — sprite exists, pulls latest
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git pull"
        {:ok, %{output: "Already up to date.", exit_code: 0}}
      end)
      # prepare_workspace (amendment) — git fetch origin && git checkout head branch
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git fetch origin"
        assert cmd =~ "git checkout -f feature/fix-tests"
        assert cmd =~ "git pull origin feature/fix-tests"
        {:ok, %{output: "Switched to branch", exit_code: 0}}
      end)
      # prepare_workspace — rm -rf .lattice/out && mkdir
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "rm -rf .lattice/out"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # sanity check
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "--- SANITY OK ---", exit_code: 0}}
      end)
      # write_prompt_file: write b64, then decode
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "printf"
        {:ok, %{output: "", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "base64 -d"
        {:ok, %{output: "", exit_code: 0}}
      end)
      # run_implementation — claude -p via streaming exec
      |> expect(:exec_ws, fn "test-ambient", cmd, _opts ->
        assert cmd =~ "claude -p"
        {:ok, start_fake_session("HANDOFF_READY: .lattice/out/")}
      end)
      # read_proposal — cat proposal.json
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "proposal.json"
        {:ok, %{output: amendment_proposal_json, exit_code: 0}}
      end)
      # validate_proposal — git diff --name-only
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git diff --name-only"
        {:ok, %{output: "test/some_test.exs", exit_code: 0}}
      end)
      # push_branch (amendment) — git push --force-with-lease
      |> expect(:exec, fn "test-ambient", cmd ->
        assert cmd =~ "git push --force-with-lease"
        assert cmd =~ "x-access-token"
        assert cmd =~ "feature/fix-tests"
        {:ok, %{output: "Branch pushed", exit_code: 0}}
      end)

      assert {:ok, result} = SpriteDelegate.handle_implementation(pr_event, [])
      assert result.branch == "feature/fix-tests"
      assert result.amendment == 203
      assert result.proposal.status == "ready"
      assert result.warnings == []
    end

    test "returns {:blocked, reason} when proposal status is blocked" do
      blocked_json =
        Jason.encode!(%{
          "protocol_version" => "bundle-v1",
          "status" => "blocked",
          "blocked_reason" => "Cannot find the module to change",
          "base_branch" => "main",
          "work_branch" => "sprite/add-dark-mode-support",
          "bundle_path" => ".lattice/out/change.bundle"
        })

      Lattice.Capabilities.MockSprites
      |> expect(:get_sprite, fn "test-ambient" -> {:ok, %{name: "test-ambient"}} end)
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "Already up to date.", exit_code: 0}}
      end)
      # prepare_workspace
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "Already on main", exit_code: 0}}
      end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      # sanity check
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: "--- SANITY OK ---", exit_code: 0}}
      end)
      # write_prompt_file
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec, fn "test-ambient", _cmd -> {:ok, %{output: "", exit_code: 0}} end)
      |> expect(:exec_ws, fn "test-ambient", _cmd, _opts ->
        {:ok, start_fake_session("HANDOFF_READY: .lattice/out/")}
      end)
      # read_proposal
      |> expect(:exec, fn "test-ambient", _cmd ->
        {:ok, %{output: blocked_json, exit_code: 0}}
      end)

      assert {:error, {:blocked, "Cannot find the module to change"}} =
               SpriteDelegate.handle_implementation(@impl_event, [])
    end
  end
end
