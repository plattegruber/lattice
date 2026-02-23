defmodule Lattice.Webhooks.GitHubRoutingTest do
  @moduledoc """
  Tests that GitHub webhook events are routed to the correct Sprite GenServer
  when a run is already in-flight for the referenced issue, PR, or branch.
  """

  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.ArtifactLink
  alias Lattice.Capabilities.GitHub.ArtifactRegistry
  alias Lattice.Intents.Store.ETS, as: StoreETS
  alias Lattice.Runs
  alias Lattice.Runs.Run
  alias Lattice.Sprites.Sprite
  alias Lattice.Webhooks.GitHub, as: WebhookHandler

  # ETS table names from ArtifactRegistry (must match the private constants)
  @artifact_primary_table :artifact_links
  @artifact_by_intent_table :artifact_links_by_intent
  @artifact_by_run_table :artifact_links_by_run

  setup do
    StoreETS.reset()

    # Clear all artifact ETS tables between tests (the registry is started by the app)
    :ets.delete_all_objects(@artifact_primary_table)
    :ets.delete_all_objects(@artifact_by_intent_table)
    :ets.delete_all_objects(@artifact_by_run_table)

    :ok
  end

  describe "issue_comment routing to existing Sprite" do
    test "routes comment to sprite when an active run exists for the issue" do
      intent_id = "intent-abc-#{System.unique_integer([:positive, :monotonic])}"
      sprite_name = unique_sprite_name()
      issue_number = System.unique_integer([:positive, :monotonic])

      # Register the artifact link: issue 42 → intent-abc
      link =
        ArtifactLink.new(%{
          intent_id: intent_id,
          kind: :issue,
          ref: issue_number,
          role: :input
        })

      ArtifactRegistry.register(link)

      # Create an active run for that intent
      {:ok, run} =
        Run.new(%{sprite_name: sprite_name, mode: :exec_ws, intent_id: intent_id})

      {:ok, run} = Run.start(run)
      Runs.Store.create(run)

      # Start a test sprite process registered under sprite_name in the real registry
      {:ok, sprite_pid} = start_test_sprite(sprite_name)

      # Subscribe to the sprite's log topic so we can verify the update was delivered
      Phoenix.PubSub.subscribe(Lattice.PubSub, "sprites:#{sprite_name}:logs")

      payload = comment_payload(issue_number, "Please review the latest changes")
      result = WebhookHandler.handle_event("issue_comment", payload)

      assert result == :ok

      assert_receive {:sprite_log, log_line}, 500
      assert log_line.source == :github_update

      stop_sprite(sprite_pid)
    end

    test "returns :ignored when no active run exists for the issue" do
      payload =
        comment_payload(
          System.unique_integer([:positive]),
          "This is a comment on an untracked issue"
        )

      result = WebhookHandler.handle_event("issue_comment", payload)

      assert result == :ignored
    end

    test "returns :ignored when run is completed (not active)" do
      intent_id = "intent-done-#{System.unique_integer([:positive, :monotonic])}"
      sprite_name = unique_sprite_name()
      issue_number = System.unique_integer([:positive, :monotonic])

      link =
        ArtifactLink.new(%{
          intent_id: intent_id,
          kind: :issue,
          ref: issue_number,
          role: :input
        })

      ArtifactRegistry.register(link)

      {:ok, run} = Run.new(%{sprite_name: sprite_name, mode: :exec_ws, intent_id: intent_id})
      {:ok, run} = Run.start(run)
      {:ok, run} = Run.complete(run)
      Runs.Store.create(run)

      payload = comment_payload(issue_number, "Great work, merging now")
      result = WebhookHandler.handle_event("issue_comment", payload)

      assert result == :ignored
    end
  end

  describe "pull_request synchronize routing to existing Sprite" do
    test "routes pr synchronize to sprite when active run exists" do
      intent_id = "intent-pr-#{System.unique_integer([:positive, :monotonic])}"
      sprite_name = unique_sprite_name()
      pr_number = System.unique_integer([:positive, :monotonic])

      link =
        ArtifactLink.new(%{
          intent_id: intent_id,
          kind: :pull_request,
          ref: pr_number,
          role: :output
        })

      ArtifactRegistry.register(link)

      {:ok, run} = Run.new(%{sprite_name: sprite_name, mode: :exec_ws, intent_id: intent_id})
      {:ok, run} = Run.start(run)
      Runs.Store.create(run)

      {:ok, sprite_pid} = start_test_sprite(sprite_name)
      Phoenix.PubSub.subscribe(Lattice.PubSub, "sprites:#{sprite_name}:logs")

      payload = pr_synchronize_payload(pr_number)
      result = WebhookHandler.handle_event("pull_request", payload)

      assert result == :ok

      assert_receive {:sprite_log, log_line}, 500
      assert log_line.source == :github_update

      stop_sprite(sprite_pid)
    end

    test "returns :ignored when no active run exists for the PR" do
      payload = pr_synchronize_payload(System.unique_integer([:positive]))
      result = WebhookHandler.handle_event("pull_request", payload)

      assert result == :ignored
    end
  end

  describe "push routing to existing Sprite" do
    test "routes branch push to sprite when active run exists" do
      intent_id = "intent-branch-#{System.unique_integer([:positive, :monotonic])}"
      sprite_name = unique_sprite_name()
      branch = "feature/my-work-#{System.unique_integer([:positive, :monotonic])}"

      link =
        ArtifactLink.new(%{
          intent_id: intent_id,
          kind: :branch,
          ref: branch,
          role: :output
        })

      ArtifactRegistry.register(link)

      {:ok, run} = Run.new(%{sprite_name: sprite_name, mode: :exec_ws, intent_id: intent_id})
      {:ok, run} = Run.start(run)
      Runs.Store.create(run)

      {:ok, sprite_pid} = start_test_sprite(sprite_name)
      Phoenix.PubSub.subscribe(Lattice.PubSub, "sprites:#{sprite_name}:logs")

      payload = push_payload("refs/heads/#{branch}")
      result = WebhookHandler.handle_event("push", payload)

      assert result == :ok

      assert_receive {:sprite_log, log_line}, 500
      assert log_line.source == :github_update

      stop_sprite(sprite_pid)
    end

    test "returns :ignored for tag pushes (not branch)" do
      payload = push_payload("refs/tags/v1.0.0")
      result = WebhookHandler.handle_event("push", payload)

      assert result == :ignored
    end

    test "returns :ignored for branch push with no active run" do
      payload = push_payload("refs/heads/unknown-branch-#{System.unique_integer([:positive])}")
      result = WebhookHandler.handle_event("push", payload)

      assert result == :ignored
    end
  end

  describe "Sprite.route_github_update/3" do
    test "delivers github_update cast to a sprite process" do
      sprite_name = unique_sprite_name()
      {:ok, sprite_pid} = start_test_sprite(sprite_name)

      Phoenix.PubSub.subscribe(Lattice.PubSub, "sprites:#{sprite_name}:logs")

      :ok =
        Sprite.route_github_update(sprite_pid, :issue_comment, %{number: 10})

      assert_receive {:sprite_log, log_line}, 500
      assert log_line.source == :github_update
      assert log_line.level == :info

      stop_sprite(sprite_pid)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp unique_sprite_name do
    "test-sprite-#{System.unique_integer([:positive, :monotonic])}"
  end

  # Start a minimal Sprite GenServer registered in Lattice.Sprites.Registry
  # so that FleetManager.get_sprite_pid/1 can find it.
  defp start_test_sprite(sprite_name) do
    Sprite.start_link(
      sprite_id: sprite_name,
      sprite_name: sprite_name,
      name: Sprite.via(sprite_name)
    )
  end

  defp stop_sprite(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  end

  defp comment_payload(issue_number, body) do
    %{
      "action" => "created",
      "issue" => %{
        "number" => issue_number,
        "title" => "Test issue",
        "body" => "Issue body",
        "labels" => []
      },
      "comment" => %{"id" => 1001, "body" => body},
      "repository" => %{"full_name" => "org/repo"},
      "sender" => %{"login" => "human-reviewer"}
    }
  end

  defp pr_synchronize_payload(pr_number) do
    %{
      "action" => "synchronize",
      "pull_request" => %{
        "number" => pr_number,
        "title" => "Test PR",
        "body" => "PR body",
        "user" => %{"login" => "author"}
      },
      "review" => %{"body" => "", "id" => 0},
      "repository" => %{"full_name" => "org/repo"},
      "sender" => %{"login" => "author"}
    }
  end

  defp push_payload(ref) do
    %{
      "ref" => ref,
      "commits" => [%{"id" => "abc123", "message" => "Add feature"}],
      "repository" => %{"full_name" => "org/repo"},
      "sender" => %{"login" => "author"}
    }
  end
end
