defmodule Lattice.PRs.TrackerTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.PRs.PR
  alias Lattice.PRs.Tracker

  describe "register/1" do
    test "registers a new PR" do
      pr = PR.new(1001, "org/tracker-test-1", intent_id: "int_reg_1")
      assert {:ok, registered} = Tracker.register(pr)
      assert registered.number == 1001
    end

    test "returns existing PR if already registered" do
      pr = PR.new(1002, "org/tracker-test-2")
      {:ok, first} = Tracker.register(pr)

      updated = %{pr | title: "Updated"}
      {:ok, second} = Tracker.register(updated)

      # Returns the original, not the updated version
      assert second.title == first.title
    end

    test "broadcasts :pr_registered event" do
      Lattice.Events.subscribe_prs()

      pr = PR.new(1003, "org/tracker-test-3")
      {:ok, _} = Tracker.register(pr)

      assert_receive {:pr_registered, %PR{number: 1003}}
    end
  end

  describe "get/2" do
    test "returns a tracked PR" do
      pr = PR.new(1010, "org/tracker-get-1")
      {:ok, _} = Tracker.register(pr)

      assert %PR{number: 1010} = Tracker.get("org/tracker-get-1", 1010)
    end

    test "returns nil for untracked PR" do
      assert Tracker.get("org/nonexistent", 9999) == nil
    end
  end

  describe "update_pr/3" do
    test "updates tracked PR fields" do
      pr = PR.new(1020, "org/tracker-update-1")
      {:ok, _} = Tracker.register(pr)

      assert {:ok, updated} =
               Tracker.update_pr("org/tracker-update-1", 1020,
                 review_state: :approved,
                 mergeable: true
               )

      assert updated.review_state == :approved
      assert updated.mergeable == true
    end

    test "returns error for untracked PR" do
      assert {:error, :not_found} = Tracker.update_pr("org/nonexistent", 8888, state: :merged)
    end

    test "broadcasts :pr_updated with changes" do
      pr = PR.new(1021, "org/tracker-update-2")
      {:ok, _} = Tracker.register(pr)

      Lattice.Events.subscribe_prs()

      {:ok, _} = Tracker.update_pr("org/tracker-update-2", 1021, review_state: :changes_requested)

      assert_receive {:pr_updated, %PR{number: 1021, review_state: :changes_requested}, changes}
      assert {:review_state, :pending, :changes_requested} in changes
    end

    test "does not broadcast when no fields changed" do
      pr = PR.new(1022, "org/tracker-update-3", review_state: :pending)
      {:ok, _} = Tracker.register(pr)

      Lattice.Events.subscribe_prs()

      {:ok, _} = Tracker.update_pr("org/tracker-update-3", 1022, review_state: :pending)

      refute_receive {:pr_updated, _, _}, 50
    end
  end

  describe "for_intent/1" do
    test "returns PRs linked to an intent" do
      pr1 = PR.new(1030, "org/tracker-intent-1", intent_id: "int_linked_1")
      pr2 = PR.new(1031, "org/tracker-intent-1", intent_id: "int_linked_1")
      {:ok, _} = Tracker.register(pr1)
      {:ok, _} = Tracker.register(pr2)

      prs = Tracker.for_intent("int_linked_1")
      numbers = Enum.map(prs, & &1.number)
      assert 1030 in numbers
      assert 1031 in numbers
    end

    test "returns empty list for unknown intent" do
      assert Tracker.for_intent("int_unknown") == []
    end
  end

  describe "by_state/1" do
    test "filters PRs by state" do
      pr1 = PR.new(1040, "org/tracker-state-1", state: :open)
      pr2 = PR.new(1041, "org/tracker-state-1", state: :open)
      {:ok, _} = Tracker.register(pr1)
      {:ok, _} = Tracker.register(pr2)
      {:ok, _} = Tracker.update_pr("org/tracker-state-1", 1041, state: :merged)

      open = Tracker.by_state(:open)
      assert Enum.any?(open, &(&1.number == 1040))

      merged = Tracker.by_state(:merged)
      assert Enum.any?(merged, &(&1.number == 1041))
    end
  end

  describe "needs_attention/0" do
    test "returns PRs that need attention" do
      pr = PR.new(1050, "org/tracker-attention-1")
      {:ok, _} = Tracker.register(pr)

      {:ok, _} =
        Tracker.update_pr("org/tracker-attention-1", 1050, review_state: :changes_requested)

      attention = Tracker.needs_attention()
      assert Enum.any?(attention, &(&1.number == 1050))
    end
  end

  describe "auto-register from artifact events" do
    test "registers PR when pull_request artifact is created" do
      alias Lattice.Capabilities.GitHub.ArtifactLink
      alias Lattice.Capabilities.GitHub.ArtifactRegistry

      link =
        ArtifactLink.new(%{
          intent_id: "int_artifact_pr",
          kind: :pull_request,
          ref: 2001,
          role: :output,
          url: "https://github.com/org/artifact-repo/pull/2001"
        })

      {:ok, _} = ArtifactRegistry.register(link)

      # Give the Tracker time to process the PubSub message
      Process.sleep(50)

      pr = Tracker.get("org/artifact-repo", 2001)
      assert pr != nil
      assert pr.number == 2001
      assert pr.intent_id == "int_artifact_pr"
    end
  end
end
