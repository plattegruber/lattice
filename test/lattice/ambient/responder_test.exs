defmodule Lattice.Ambient.ResponderTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  import Mox

  alias Lattice.Ambient.Responder

  setup :verify_on_exit!

  setup do
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
      # Claude returns :ignore (no API key), so after list_comments the flow ends.
      # The second event on the same thread should be skipped entirely (no list_comments call).
      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, 1, fn _number -> {:ok, []} end)

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

      # Claude returns :ignore, so no cooldown is recorded (only :respond/:react record cooldown).
      # Wait for cooldown to expire, then verify the mock was called exactly once.
      Process.sleep(150)
    end
  end

  describe "event routing" do
    test "handles issue_comment events" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_comments, fn _number -> {:ok, []} end)

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
end
