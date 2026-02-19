defmodule Lattice.PRs.PostFixupCommenterTest do
  use ExUnit.Case, async: false

  import Mox

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store
  alias Lattice.PRs.PostFixupCommenter

  setup :set_mox_global
  setup :verify_on_exit!

  defp create_fixup_intent(opts \\ []) do
    pr_number = Keyword.get(opts, :pr_number, 42)

    {:ok, intent} =
      Intent.new(:pr_fixup, %{type: :system, id: "test_1"},
        summary: "Fix review feedback on PR ##{pr_number}",
        payload: %{
          "pr_url" => "https://github.com/org/repo/pull/#{pr_number}",
          "feedback" => Keyword.get(opts, :feedback, "Fix the typo in README.md"),
          "pr_title" => "Add feature",
          "reviewer" => "reviewer1"
        }
      )

    {:ok, stored} = Store.create(intent)
    stored
  end

  defp make_run(intent, opts \\ []) do
    %{
      id: "run_test_#{:erlang.unique_integer([:positive])}",
      intent_id: intent.id,
      sprite_name: Keyword.get(opts, :sprite_name, "atlas"),
      status: Keyword.get(opts, :status, :completed),
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      error: Keyword.get(opts, :error),
      artifacts: Keyword.get(opts, :artifacts, [])
    }
  end

  describe "run completion handling" do
    test "posts comment on PR after successful fixup run" do
      intent = create_fixup_intent()
      run = make_run(intent, artifacts: [%{type: "commit", data: "abc123def456"}])

      Lattice.Capabilities.MockGitHub
      |> expect(:create_comment, fn 42, body ->
        assert body =~ "Fixup Success"
        assert body =~ intent.id
        assert body =~ "abc123def456"
        assert body =~ "Fix the typo"
        {:ok, %{"id" => 1}}
      end)

      # Broadcast directly to the commenter
      Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_completed, run})
      Process.sleep(50)
    end

    test "posts comment on PR after failed fixup run" do
      intent = create_fixup_intent(pr_number: 99)
      run = make_run(intent, status: :failed, error: {:sprite_exec_failed, :timeout})

      Lattice.Capabilities.MockGitHub
      |> expect(:create_comment, fn 99, body ->
        assert body =~ "Fixup Failed"
        assert body =~ "sprite_exec_failed"
        {:ok, %{"id" => 2}}
      end)

      Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_completed, run})
      Process.sleep(50)
    end

    test "ignores runs without intent_id" do
      run = %{id: "run_orphan", intent_id: nil, status: :completed}

      # No mock expectations — should not call GitHub
      Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_completed, run})
      Process.sleep(50)
    end

    test "ignores runs for non-pr_fixup intents" do
      {:ok, intent} =
        Intent.new(:action, %{type: :system, id: "test_2"},
          summary: "Some action",
          payload: %{"capability" => "github", "operation" => "create_issue"}
        )

      {:ok, stored} = Store.create(intent)
      run = make_run(stored)

      # No mock expectations — should not call GitHub
      Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_completed, run})
      Process.sleep(50)
    end

    test "handles GitHub comment failure gracefully" do
      intent = create_fixup_intent(pr_number: 55)
      run = make_run(intent)

      Lattice.Capabilities.MockGitHub
      |> expect(:create_comment, fn 55, _body -> {:error, :rate_limited} end)

      Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_completed, run})
      Process.sleep(50)
    end
  end

  describe "build_comment/2" do
    test "includes commit SHA when present" do
      intent = create_fixup_intent()
      run = make_run(intent, artifacts: [%{type: "commit", data: "abc123"}])

      comment = PostFixupCommenter.build_comment(run, intent)
      assert comment =~ "`abc123`"
    end

    test "omits commit SHA when not present" do
      intent = create_fixup_intent()
      run = make_run(intent, artifacts: [])

      comment = PostFixupCommenter.build_comment(run, intent)
      refute comment =~ "Commit:"
    end

    test "includes feedback quote" do
      intent = create_fixup_intent(feedback: "Fix the naming convention")
      run = make_run(intent)

      comment = PostFixupCommenter.build_comment(run, intent)
      assert comment =~ "Fix the naming convention"
    end

    test "includes run details section" do
      intent = create_fixup_intent()
      run = make_run(intent, sprite_name: "sprite-01")

      comment = PostFixupCommenter.build_comment(run, intent)
      assert comment =~ "sprite-01"
      assert comment =~ "Run details"
    end
  end
end
