defmodule Lattice.Webhooks.GitHubAmbientTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Events
  alias Lattice.Intents.Store.ETS, as: StoreETS
  alias Lattice.Webhooks.GitHub, as: WebhookHandler

  setup do
    StoreETS.reset()
    Events.subscribe_ambient()
    :ok
  end

  describe "ambient broadcasting for issue_comment" do
    test "broadcasts ambient event for human comments" do
      payload = %{
        "action" => "created",
        "issue" => %{
          "number" => 10,
          "title" => "Regular issue",
          "body" => "Just a normal issue",
          "labels" => []
        },
        "comment" => %{
          "id" => 12345,
          "body" => "What do you think about this?"
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "human-user"}
      }

      WebhookHandler.handle_event("issue_comment", payload)

      assert_receive {:ambient_event, event}
      assert event.type == :issue_comment
      assert event.surface == :issue
      assert event.number == 10
      assert event.body == "What do you think about this?"
      assert event.author == "human-user"
      assert event.comment_id == 12345
    end

    test "does not broadcast ambient event for bot comments" do
      payload = %{
        "action" => "created",
        "issue" => %{
          "number" => 10,
          "title" => "Regular issue",
          "body" => "Just a normal issue",
          "labels" => []
        },
        "comment" => %{
          "id" => 12345,
          "body" => "Auto-merged by bot"
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "dependabot[bot]"}
      }

      WebhookHandler.handle_event("issue_comment", payload)

      refute_receive {:ambient_event, _}, 100
    end

    test "does not broadcast ambient event for github-actions" do
      payload = %{
        "action" => "created",
        "issue" => %{
          "number" => 10,
          "title" => "CI report",
          "body" => "CI issue",
          "labels" => []
        },
        "comment" => %{
          "id" => 999,
          "body" => "CI passed"
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "github-actions"}
      }

      WebhookHandler.handle_event("issue_comment", payload)

      refute_receive {:ambient_event, _}, 100
    end

    test "does not broadcast ambient event for comments with lattice sentinel markers" do
      payload = %{
        "action" => "created",
        "issue" => %{
          "number" => 10,
          "title" => "Some issue",
          "body" => "Normal issue",
          "labels" => []
        },
        "comment" => %{
          "id" => 888,
          "body" => "Here is my response\n\n<!-- lattice:ambient -->"
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "real-human"}
      }

      WebhookHandler.handle_event("issue_comment", payload)

      refute_receive {:ambient_event, _}, 100
    end

    test "does not broadcast ambient event for configured bot login" do
      Application.put_env(:lattice, Lattice.Ambient.Responder,
        enabled: true,
        bot_login: "lattice-operator",
        cooldown_ms: 60_000,
        eyes_reaction: true
      )

      payload = %{
        "action" => "created",
        "issue" => %{
          "number" => 10,
          "title" => "Some issue",
          "body" => "Normal issue",
          "labels" => []
        },
        "comment" => %{
          "id" => 777,
          "body" => "Just a normal comment"
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "lattice-operator"}
      }

      WebhookHandler.handle_event("issue_comment", payload)

      refute_receive {:ambient_event, _}, 100
    end
  end

  describe "ambient broadcasting for issues.opened" do
    test "broadcasts ambient event when issue is opened" do
      payload = %{
        "action" => "opened",
        "issue" => %{
          "number" => 42,
          "title" => "New feature request",
          "body" => "Please add dark mode",
          "labels" => []
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "contributor"}
      }

      WebhookHandler.handle_event("issues", payload)

      assert_receive {:ambient_event, event}
      assert event.type == :issue_opened
      assert event.surface == :issue
      assert event.number == 42
      assert event.body == "Please add dark mode"
      assert event.author == "contributor"
    end
  end

  describe "ambient broadcasting for pull_request_review" do
    test "broadcasts ambient event for PR review" do
      payload = %{
        "action" => "submitted",
        "review" => %{
          "id" => 777,
          "body" => "Looks good overall",
          "state" => "approved",
          "user" => %{"login" => "reviewer"}
        },
        "pull_request" => %{
          "number" => 88,
          "title" => "Add feature X"
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "reviewer"}
      }

      WebhookHandler.handle_event("pull_request_review", payload)

      assert_receive {:ambient_event, event}
      assert event.type == :pr_review
      assert event.surface == :pr_review
      assert event.number == 88
      assert event.body == "Looks good overall"
      assert event.author == "reviewer"
    end
  end

  describe "ambient broadcasting for pull_request_review_comment" do
    test "broadcasts ambient event for PR review comment" do
      payload = %{
        "action" => "created",
        "comment" => %{
          "id" => 555,
          "body" => "Nit: use snake_case here"
        },
        "pull_request" => %{
          "number" => 88,
          "title" => "Add feature X"
        },
        "repository" => %{"full_name" => "org/repo"},
        "sender" => %{"login" => "reviewer"}
      }

      WebhookHandler.handle_event("pull_request_review_comment", payload)

      assert_receive {:ambient_event, event}
      assert event.type == :pr_review_comment
      assert event.surface == :pr_review_comment
      assert event.number == 88
      assert event.body == "Nit: use snake_case here"
      assert event.comment_id == 555
    end
  end
end
