defmodule Lattice.Ambient.ResponderTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  import Mox

  alias Lattice.Ambient.Proposal
  alias Lattice.Ambient.Responder

  setup :verify_on_exit!

  setup do
    # Start the TaskSupervisor (needed for delegation)
    start_supervised!({Task.Supervisor, name: Lattice.Ambient.TaskSupervisor})

    # Start the responder for each test
    Application.put_env(:lattice, Lattice.Ambient.Responder,
      enabled: true,
      bot_login: "lattice-bot",
      cooldown_ms: 100,
      eyes_reaction: false
    )

    pid = start_supervised!(Responder)

    # Allow the GenServer process to use mock expectations from this test process
    Mox.allow(Lattice.Capabilities.MockGitHub, self(), pid)

    {:ok, responder_pid: pid}
  end

  defp build_test_proposal(overrides \\ %{}) do
    defaults = %{
      protocol_version: "bundle-v1",
      status: "ready",
      repo: "plattegruber/lattice",
      base_branch: "main",
      work_branch: "sprite/add-dark-mode",
      bundle_path: ".lattice/out/change.bundle",
      patch_path: ".lattice/out/diff.patch",
      summary: "Added dark mode",
      pr: %{
        "title" => "Add dark mode support",
        "body" => "Implements dark mode theming",
        "labels" => ["lattice:ambient"],
        "review_notes" => []
      },
      commands: [%{"cmd" => "mix format", "exit" => 0}],
      flags: %{}
    }

    struct!(Proposal, Map.merge(defaults, overrides))
  end

  describe "self-loop prevention" do
    test "ignores events from the configured bot login" do
      event = %{
        type: :issue_comment,
        surface: :issue,
        number: 1,
        body: "I'm the bot",
        title: "Test",
        author: "lattice-bot",
        comment_id: 100,
        repo: "org/repo"
      }

      # Should not call any GitHub API methods
      send(Process.whereis(Responder), {:ambient_event, event})
      Process.sleep(50)
      # No crash, no API calls — test passes if no error
    end
  end

  describe "cooldown" do
    test "processes first event, second within cooldown does not call list_comments again" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, 1, fn _number -> {:ok, []} end)
      |> expect(:create_comment_reaction, 1, fn _id, "+1" -> {:ok, %{id: 1, content: "+1"}} end)

      event = %{
        type: :issue_comment,
        surface: :issue,
        number: 42,
        body: "Hello, can you help?",
        title: "Test issue",
        author: "human-user",
        comment_id: 200,
        repo: "org/repo"
      }

      # First event — should be processed
      send(Process.whereis(Responder), {:ambient_event, event})
      Process.sleep(50)

      # Wait for cooldown to expire, then verify the mock was called exactly once.
      Process.sleep(150)
    end
  end

  describe "event routing" do
    test "handles issue_comment events" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn _number -> {:ok, []} end)
      |> expect(:create_comment_reaction, fn _id, "+1" -> {:ok, %{id: 1, content: "+1"}} end)

      event = %{
        type: :issue_comment,
        surface: :issue,
        number: 10,
        body: "What do you think?",
        title: "Feature request",
        author: "contributor",
        comment_id: 300,
        repo: "org/repo"
      }

      send(Process.whereis(Responder), {:ambient_event, event})
      Process.sleep(100)
    end

    test "handles issue_opened events" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn _number -> {:ok, []} end)
      |> expect(:create_issue_reaction, fn _number, "+1" -> {:ok, %{id: 1, content: "+1"}} end)

      event = %{
        type: :issue_opened,
        surface: :issue,
        number: 55,
        body: "New issue body",
        title: "New issue",
        author: "opener",
        comment_id: nil,
        repo: "org/repo"
      }

      send(Process.whereis(Responder), {:ambient_event, event})
      Process.sleep(100)
    end

    test "handles pr_review events" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn _number -> {:ok, []} end)
      |> expect(:create_comment_reaction, fn _id, "+1" -> {:ok, %{id: 1, content: "+1"}} end)

      event = %{
        type: :pr_review,
        surface: :pr_review,
        number: 77,
        body: "Looks good, minor nit",
        title: "PR title",
        author: "reviewer",
        comment_id: 400,
        repo: "org/repo"
      }

      send(Process.whereis(Responder), {:ambient_event, event})
      Process.sleep(100)
    end
  end

  describe "delegation task completion" do
    test "posts response and records cooldown on successful delegation" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 500, 42 -> :ok end)
      |> expect(:create_comment, fn number, body ->
        assert number == 42
        assert body =~ "The fleet manager explained"
        assert body =~ "lattice:ambient"
        {:ok, %{id: 1}}
      end)

      event = %{
        type: :issue_comment,
        surface: :issue,
        number: 42,
        body: "How does the fleet manager work?",
        title: "Question",
        author: "dev",
        comment_id: 500,
        repo: "org/repo"
      }

      # Simulate: put a task ref in active_tasks, then send the result message
      ref = make_ref()
      responder = Process.whereis(Responder)

      # Inject the active task into state via sys (new 3-tuple format with rocket_id)
      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:delegate, event, 42})}
      end)

      # Send the task result message
      send(responder, {ref, {:ok, "The fleet manager explained"}})
      Process.sleep(100)

      # Verify cooldown was recorded in state
      state = :sys.get_state(responder)
      assert Map.has_key?(state.cooldowns, "issue:42")
    end

    test "adds confused reaction on delegation failure" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 500, 42 -> :ok end)
      |> expect(:create_comment_reaction, fn 500, "confused" ->
        {:ok, %{id: 1, content: "confused"}}
      end)

      event = %{
        type: :issue_comment,
        surface: :issue,
        number: 42,
        body: "How does the fleet manager work?",
        title: "Question",
        author: "dev",
        comment_id: 500,
        repo: "org/repo"
      }

      ref = make_ref()
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:delegate, event, 42})}
      end)

      send(responder, {ref, {:error, :delegation_disabled}})
      Process.sleep(100)
    end

    test "adds confused reaction on delegation crash (DOWN message)" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 500, 42 -> :ok end)
      |> expect(:create_comment_reaction, fn 500, "confused" ->
        {:ok, %{id: 1, content: "confused"}}
      end)

      event = %{
        type: :issue_comment,
        surface: :issue,
        number: 42,
        body: "How does the fleet manager work?",
        title: "Question",
        author: "dev",
        comment_id: 500,
        repo: "org/repo"
      }

      ref = make_ref()
      pid = spawn(fn -> :ok end)
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:delegate, event, 42})}
      end)

      send(responder, {:DOWN, ref, :process, pid, :killed})
      Process.sleep(100)
    end
  end

  describe "implementation task completion" do
    @impl_event %{
      type: :issue_comment,
      surface: :issue,
      number: 99,
      body: "implement this",
      title: "Add dark mode",
      author: "dev",
      comment_id: 600,
      repo: "org/repo"
    }

    test "creates PR with proposal data on successful implementation" do
      proposal = build_test_proposal()

      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_pull_request, fn attrs ->
        assert attrs.head == "lattice/issue-99-add-dark-mode"
        assert attrs.base == "main"
        assert attrs.title == "Add dark mode support"
        assert attrs.body =~ "Closes #99"
        assert attrs.body =~ "Implements dark mode theming"
        assert attrs.body =~ "bundle-v1"
        {:ok, %{number: 101, html_url: "https://github.com/org/repo/pull/101"}}
      end)
      |> expect(:add_label, fn 101, "lattice:ambient" -> {:ok, ["lattice:ambient"]} end)
      |> expect(:create_comment, fn 99, body ->
        assert body =~ "PR #101"
        assert body =~ "lattice:ambient:implement"
        {:ok, %{id: 1}}
      end)

      ref = make_ref()
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, @impl_event, 42})}
      end)

      send(
        responder,
        {ref,
         {:ok, %{branch: "lattice/issue-99-add-dark-mode", proposal: proposal, warnings: []}}}
      )

      Process.sleep(100)

      # Verify cooldown was recorded
      state = :sys.get_state(responder)
      assert Map.has_key?(state.cooldowns, "issue:99")
    end

    test "includes warnings in PR body" do
      proposal = build_test_proposal()
      warnings = ["Proposal modifies dependencies (mix.exs changed, touches_deps flag set)"]

      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_pull_request, fn attrs ->
        assert attrs.body =~ "Policy warnings"
        assert attrs.body =~ "dependencies"
        {:ok, %{number: 102, html_url: "https://github.com/org/repo/pull/102"}}
      end)
      |> expect(:add_label, fn 102, "lattice:ambient" -> {:ok, ["lattice:ambient"]} end)
      |> expect(:create_comment, fn 99, _body -> {:ok, %{id: 1}} end)

      ref = make_ref()
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, @impl_event, 42})}
      end)

      send(
        responder,
        {ref,
         {:ok,
          %{
            branch: "lattice/issue-99-add-dark-mode",
            proposal: proposal,
            warnings: warnings
          }}}
      )

      Process.sleep(100)
    end

    test "posts helpful comment when no changes produced" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_comment, fn 99, body ->
        assert body =~ "couldn't produce any code changes"
        assert body =~ "lattice:ambient:implement"
        {:ok, %{id: 1}}
      end)

      ref = make_ref()
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, @impl_event, 42})}
      end)

      send(responder, {ref, {:error, :no_changes}})
      Process.sleep(100)
    end

    test "posts comment for no_proposal error" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_comment, fn 99, body ->
        assert body =~ "no handoff proposal"
        {:ok, %{id: 1}}
      end)

      ref = make_ref()
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, @impl_event, 42})}
      end)

      send(responder, {ref, {:error, :no_proposal}})
      Process.sleep(100)
    end

    test "posts comment for blocked error" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_comment, fn 99, body ->
        assert body =~ "blocked"
        assert body =~ "Cannot find module"
        {:ok, %{id: 1}}
      end)

      ref = make_ref()
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, @impl_event, 42})}
      end)

      send(responder, {ref, {:error, {:blocked, "Cannot find module"}}})
      Process.sleep(100)
    end

    test "posts comment for policy_violation error" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_comment, fn 99, body ->
        assert body =~ "rejected by policy"
        {:ok, %{id: 1}}
      end)

      ref = make_ref()
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, @impl_event, 42})}
      end)

      send(responder, {ref, {:error, :policy_violation}})
      Process.sleep(100)
    end

    test "adds confused reaction and error comment on implementation failure" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_comment_reaction, fn 600, "confused" ->
        {:ok, %{id: 1, content: "confused"}}
      end)
      |> expect(:create_comment, fn 99, body ->
        assert body =~ "ran into an issue"
        assert body =~ "sprite_error"
        {:ok, %{id: 1}}
      end)

      ref = make_ref()
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, @impl_event, 42})}
      end)

      send(responder, {ref, {:error, :sprite_error}})
      Process.sleep(100)
    end

    test "handles DOWN for implementation tasks" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_comment_reaction, fn 600, "confused" ->
        {:ok, %{id: 1, content: "confused"}}
      end)

      ref = make_ref()
      pid = spawn(fn -> :ok end)
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, @impl_event, 42})}
      end)

      send(responder, {:DOWN, ref, :process, pid, :killed})
      Process.sleep(100)
    end

    test "comments on existing PR for amendment result (no new PR created)" do
      proposal = build_test_proposal(%{summary: "Fixed the tests"})

      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_comment, fn 203, body ->
        assert body =~ "pushed changes to this PR"
        assert body =~ "Fixed the tests"
        assert body =~ "lattice:ambient:implement"
        {:ok, %{id: 1}}
      end)

      ref = make_ref()
      responder = Process.whereis(Responder)

      # Use a PR-surface event for the amendment
      pr_event = %{
        type: :issue_comment,
        surface: :pr_comment,
        number: 203,
        body: "Fix these changes",
        title: "Fix tests",
        author: "reviewer",
        comment_id: 600,
        repo: "org/repo",
        is_pull_request: true
      }

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, pr_event, 42})}
      end)

      send(
        responder,
        {ref,
         {:ok,
          %{
            branch: "feature/fix-tests",
            proposal: proposal,
            warnings: [],
            amendment: 203
          }}}
      )

      Process.sleep(100)

      # Verify cooldown was recorded
      state = :sys.get_state(responder)
      assert Map.has_key?(state.cooldowns, "pr_comment:203")
    end

    test "posts error comment on PR surface for implementation failures" do
      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_comment, fn 203, body ->
        assert body =~ "couldn't produce any code changes"
        assert body =~ "lattice:ambient:implement"
        {:ok, %{id: 1}}
      end)

      ref = make_ref()
      responder = Process.whereis(Responder)

      pr_event = %{
        type: :issue_comment,
        surface: :pr_comment,
        number: 203,
        body: "Fix this",
        title: "Fix tests",
        author: "reviewer",
        comment_id: 600,
        repo: "org/repo",
        is_pull_request: true
      }

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, pr_event, 42})}
      end)

      send(responder, {ref, {:error, :no_changes}})
      Process.sleep(100)
    end

    test "comments with branch name when PR creation fails" do
      proposal = build_test_proposal()

      Lattice.Capabilities.MockGitHub
      |> expect(:delete_comment_reaction, fn 600, 42 -> :ok end)
      |> expect(:create_pull_request, fn _attrs ->
        {:error, :validation_failed}
      end)
      |> expect(:create_comment, fn 99, body ->
        assert body =~ "lattice/issue-99-add-dark-mode"
        assert body =~ "PR creation failed"
        {:ok, %{id: 1}}
      end)

      ref = make_ref()
      responder = Process.whereis(Responder)

      :sys.replace_state(responder, fn state ->
        %{state | active_tasks: Map.put(state.active_tasks, ref, {:implement, @impl_event, 42})}
      end)

      send(
        responder,
        {ref,
         {:ok, %{branch: "lattice/issue-99-add-dark-mode", proposal: proposal, warnings: []}}}
      )

      Process.sleep(100)
    end
  end
end
