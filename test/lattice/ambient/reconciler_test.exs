defmodule Lattice.Ambient.ReconcilerTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  import Mox

  alias Lattice.Ambient.Reconciler
  alias Lattice.Events

  setup :verify_on_exit!

  setup do
    # Configure responder bot login for filtering
    Application.put_env(:lattice, Lattice.Ambient.Responder,
      enabled: true,
      bot_login: "lattice-bot"
    )

    # Configure reconciler with zero delay for tests
    Application.put_env(:lattice, Lattice.Ambient.Reconciler,
      lookback_ms: :timer.minutes(10),
      startup_delay_ms: 0
    )

    # Subscribe to ambient events so we can verify broadcasts
    Events.subscribe_ambient()

    :ok
  end

  describe "find_missed_comments/2" do
    test "returns empty when all recent comments have bot replies" do
      issues = [
        %{number: 1, title: "Test issue", body: "Issue body", state: "open", labels: []}
      ]

      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn 1 ->
        {:ok,
         [
           %{id: 100, body: "Please fix this", user: "alice", created_at: "2026-02-25T03:00:00Z"},
           %{
             id: 101,
             body: "Done!\n\n<!-- lattice:ambient -->",
             user: "lattice-bot",
             created_at: "2026-02-25T03:05:00Z"
           }
         ]}
      end)

      assert Reconciler.find_missed_comments(issues, "lattice-bot") == []
    end

    test "detects missed comment when last human comment has no lattice reply" do
      issues = [
        %{number: 42, title: "Bug report", body: "Something broke", state: "open", labels: []}
      ]

      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn 42 ->
        {:ok,
         [
           %{
             id: 200,
             body: "Can you look into this?",
             user: "alice",
             created_at: "2026-02-25T03:04:00Z"
           }
         ]}
      end)

      result = Reconciler.find_missed_comments(issues, "lattice-bot")
      assert length(result) == 1
      assert %{issue: issue, comment: comment} = hd(result)
      assert issue.number == 42
      assert comment[:id] == 200
      assert comment[:body] == "Can you look into this?"
    end

    test "ignores bot comments" do
      issues = [
        %{number: 5, title: "Issue", body: "Body", state: "open", labels: []}
      ]

      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn 5 ->
        {:ok,
         [
           %{
             id: 300,
             body: "Automated update",
             user: "dependabot[bot]",
             created_at: "2026-02-25T03:00:00Z"
           }
         ]}
      end)

      assert Reconciler.find_missed_comments(issues, "lattice-bot") == []
    end

    test "ignores lattice-marker comments" do
      issues = [
        %{number: 6, title: "Issue", body: "Body", state: "open", labels: []}
      ]

      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn 6 ->
        {:ok,
         [
           %{
             id: 400,
             body: "Done!\n\n<!-- lattice:ambient:implement -->",
             user: "lattice-bot",
             created_at: "2026-02-25T03:00:00Z"
           }
         ]}
      end)

      assert Reconciler.find_missed_comments(issues, "lattice-bot") == []
    end

    test "processes multiple issues correctly" do
      issues = [
        %{number: 10, title: "Issue A", body: "Body A", state: "open", labels: []},
        %{number: 11, title: "Issue B", body: "Body B", state: "open", labels: []}
      ]

      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn 10 ->
        {:ok,
         [
           %{id: 500, body: "Help needed", user: "alice", created_at: "2026-02-25T03:00:00Z"},
           %{
             id: 501,
             body: "On it\n\n<!-- lattice:ambient -->",
             user: "lattice-bot",
             created_at: "2026-02-25T03:01:00Z"
           }
         ]}
      end)
      |> expect(:list_comments, fn 11 ->
        {:ok,
         [
           %{
             id: 600,
             body: "This needs attention",
             user: "bob",
             created_at: "2026-02-25T03:04:00Z"
           }
         ]}
      end)

      result = Reconciler.find_missed_comments(issues, "lattice-bot")
      assert length(result) == 1
      assert hd(result).issue.number == 11
    end

    test "handles API failure gracefully" do
      issues = [
        %{number: 99, title: "Issue", body: "Body", state: "open", labels: []}
      ]

      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn 99 ->
        {:error, :rate_limited}
      end)

      assert Reconciler.find_missed_comments(issues, "lattice-bot") == []
    end

    test "only flags last human comment, not earlier ones" do
      issues = [
        %{number: 20, title: "Issue", body: "Body", state: "open", labels: []}
      ]

      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn 20 ->
        {:ok,
         [
           %{id: 700, body: "First comment", user: "alice", created_at: "2026-02-25T02:00:00Z"},
           %{
             id: 701,
             body: "Replied\n\n<!-- lattice:ambient -->",
             user: "lattice-bot",
             created_at: "2026-02-25T02:05:00Z"
           },
           %{
             id: 702,
             body: "Follow up question",
             user: "alice",
             created_at: "2026-02-25T03:04:00Z"
           }
         ]}
      end)

      result = Reconciler.find_missed_comments(issues, "lattice-bot")
      assert length(result) == 1
      assert hd(result).comment[:id] == 702
    end
  end

  describe "startup reconciliation" do
    test "broadcasts missed events on boot" do
      issues = [
        %{number: 50, title: "Deploy issue", body: "Issue body", state: "open", labels: []}
      ]

      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn opts ->
        assert Keyword.get(opts, :state) == "open"
        assert Keyword.get(opts, :limit) == 30
        assert Keyword.get(opts, :since) != nil
        {:ok, issues}
      end)
      |> expect(:list_comments, fn 50 ->
        {:ok,
         [
           %{id: 800, body: "Missed comment", user: "alice", created_at: "2026-02-25T03:04:00Z"}
         ]}
      end)

      pid = start_supervised!(Reconciler)

      # Allow the mock to be called from the GenServer process
      Mox.allow(Lattice.Capabilities.MockGitHub, self(), pid)

      # Wait for reconciliation to complete
      assert_receive {:ambient_event, event}, 5_000
      assert event.type == :issue_comment
      assert event.number == 50
      assert event.body == "Missed comment"
      assert event.author == "alice"
      assert event.comment_id == 800
    end

    test "no broadcast when nothing is missed" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts ->
        {:ok, []}
      end)

      pid = start_supervised!(Reconciler)
      Mox.allow(Lattice.Capabilities.MockGitHub, self(), pid)

      # Give it time to reconcile, verify no event
      Process.sleep(200)
      refute_received {:ambient_event, _}
    end

    test "handles list_issues failure without crashing" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts ->
        {:error, :unauthorized}
      end)

      pid = start_supervised!(Reconciler)
      Mox.allow(Lattice.Capabilities.MockGitHub, self(), pid)

      # Give it time to reconcile — should not crash
      Process.sleep(200)
      assert Process.alive?(pid)
    end
  end
end
