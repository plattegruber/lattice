defmodule Lattice.Webhooks.GitHubTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Intents.Store.ETS, as: StoreETS
  alias Lattice.Webhooks.GitHub, as: WebhookHandler

  setup do
    StoreETS.reset()
    :ok
  end

  # ── issues.opened ──────────────────────────────────────────────────

  describe "issues.opened" do
    test "proposes action intent when issue has lattice-work label" do
      payload = issue_payload("opened", labels: ["lattice-work"])

      assert {:ok, intent} = WebhookHandler.handle_event("issues", payload)
      assert intent.kind == :action
      assert intent.source.type == :webhook
      assert intent.source.id == "github:issues:42"
      assert String.contains?(intent.summary, "Triage issue #42")
      assert intent.payload["operation"] == "issue_triage"
      assert intent.payload["repo"] == "org/repo"
    end

    test "ignores issue without lattice-work label" do
      payload = issue_payload("opened", labels: ["bug", "help-wanted"])

      assert :ignored = WebhookHandler.handle_event("issues", payload)
    end

    test "ignores issue with no labels" do
      payload = issue_payload("opened", labels: [])

      assert :ignored = WebhookHandler.handle_event("issues", payload)
    end
  end

  # ── issues.labeled ─────────────────────────────────────────────────

  describe "issues.labeled" do
    test "proposes action intent when lattice-work label is added" do
      payload =
        issue_payload("labeled", labels: ["lattice-work"])
        |> Map.put("label", %{"name" => "lattice-work"})

      assert {:ok, intent} = WebhookHandler.handle_event("issues", payload)
      assert intent.kind == :action
      assert intent.payload["operation"] == "issue_triage"
    end

    test "ignores when non-trigger label is added" do
      payload =
        issue_payload("labeled", labels: ["bug", "lattice-work"])
        |> Map.put("label", %{"name" => "bug"})

      assert :ignored = WebhookHandler.handle_event("issues", payload)
    end
  end

  # ── pull_request.review_submitted ──────────────────────────────────

  describe "pull_request.review_submitted" do
    test "proposes action intent when changes_requested" do
      payload = pr_review_payload("changes_requested")

      assert {:ok, intent} = WebhookHandler.handle_event("pull_request", payload)
      assert intent.kind == :action
      assert intent.source.type == :webhook
      assert intent.payload["operation"] == "pr_fixup"
      assert intent.payload["pr_number"] == 99
      assert intent.payload["reviewer"] == "reviewer-user"
    end

    test "ignores approved review" do
      payload = pr_review_payload("approved")

      assert :ignored = WebhookHandler.handle_event("pull_request", payload)
    end

    test "ignores commented review" do
      payload = pr_review_payload("commented")

      assert :ignored = WebhookHandler.handle_event("pull_request", payload)
    end
  end

  # ── issue_comment.created (governance sync) ────────────────────────

  describe "issue_comment.created" do
    test "ignores comments on non-governance issues" do
      payload = %{
        "action" => "created",
        "issue" => %{
          "number" => 10,
          "title" => "Regular issue",
          "body" => "Just a normal issue",
          "labels" => []
        },
        "comment" => %{"body" => "Nice work!"}
      }

      assert :ignored = WebhookHandler.handle_event("issue_comment", payload)
    end
  end

  # ── Ambient event: is_pull_request detection ─────────────────────

  describe "ambient event: is_pull_request" do
    test "build_ambient_event sets is_pull_request: true for PR comments" do
      # GitHub sends issue_comment events for PR comments too,
      # with issue.pull_request present in the payload
      payload = %{
        "action" => "created",
        "issue" => %{
          "number" => 203,
          "title" => "Fix tests",
          "body" => "PR body",
          "labels" => [],
          "pull_request" => %{"url" => "https://api.github.com/repos/org/repo/pulls/203"},
          "user" => %{"login" => "author"}
        },
        "comment" => %{
          "id" => 999,
          "body" => "Fix these changes and commit them to our branch"
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "human-user"}
      }

      # The ambient event is broadcast via PubSub — subscribe to capture it
      Lattice.Events.subscribe_ambient()
      WebhookHandler.handle_event("issue_comment", payload)

      assert_receive {:ambient_event, event}, 500
      assert event.is_pull_request == true
      assert event.surface == :pr_comment
      assert event.number == 203
    end

    test "build_ambient_event sets is_pull_request: false for regular issue comments" do
      payload = %{
        "action" => "created",
        "issue" => %{
          "number" => 42,
          "title" => "Bug report",
          "body" => "Issue body",
          "labels" => [],
          "user" => %{"login" => "author"}
        },
        "comment" => %{
          "id" => 888,
          "body" => "Any update on this?"
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "human-user"}
      }

      Lattice.Events.subscribe_ambient()
      WebhookHandler.handle_event("issue_comment", payload)

      assert_receive {:ambient_event, event}, 500
      assert event.is_pull_request == false
      assert event.surface == :issue
    end

    test "build_ambient_event sets is_pull_request: true for pr_review events" do
      payload = %{
        "action" => "submitted",
        "pull_request" => %{
          "number" => 77,
          "title" => "PR title",
          "body" => "PR body",
          "user" => %{"login" => "author"}
        },
        "review" => %{
          "id" => 555,
          "body" => "Looks good",
          "state" => "approved"
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "reviewer"}
      }

      Lattice.Events.subscribe_ambient()
      WebhookHandler.handle_event("pull_request_review", payload)

      assert_receive {:ambient_event, event}, 500
      assert event.is_pull_request == true
    end
  end

  # ── Unhandled events ───────────────────────────────────────────────

  describe "unhandled events" do
    test "ignores push events" do
      assert :ignored = WebhookHandler.handle_event("push", %{})
    end

    test "ignores ping events" do
      assert :ignored = WebhookHandler.handle_event("ping", %{"zen" => "test"})
    end

    test "ignores unknown events" do
      assert :ignored = WebhookHandler.handle_event("deployment", %{})
    end

    test "ignores issues.closed" do
      payload = issue_payload("closed", labels: ["lattice-work"])
      assert :ignored = WebhookHandler.handle_event("issues", payload)
    end
  end

  # ── Test Helpers ───────────────────────────────────────────────────

  defp issue_payload(action, opts) do
    labels = Keyword.get(opts, :labels, [])

    %{
      "action" => action,
      "issue" => %{
        "number" => 42,
        "title" => "Test issue title",
        "body" => "Test issue body",
        "labels" => Enum.map(labels, &%{"name" => &1})
      },
      "repository" => %{"full_name" => "org/repo"},
      "sender" => %{"login" => "test-user"}
    }
  end

  defp pr_review_payload(review_state) do
    %{
      "action" => "review_submitted",
      "pull_request" => %{
        "number" => 99,
        "title" => "Fix the thing"
      },
      "review" => %{
        "state" => review_state,
        "body" => "Please fix the tests",
        "user" => %{"login" => "reviewer-user"}
      },
      "repository" => %{"full_name" => "org/repo"},
      "sender" => %{"login" => "reviewer-user"}
    }
  end
end
