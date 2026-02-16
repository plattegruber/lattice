defmodule Lattice.Capabilities.GitHub.WorkProposalTest do
  use ExUnit.Case, async: true

  import Mox

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.WorkProposal

  setup :verify_on_exit!

  describe "propose_work/2" do
    test "creates a GitHub issue with proposed label" do
      Lattice.Capabilities.MockGitHub
      |> expect(:create_issue, fn title, attrs ->
        assert title =~ "[Sprite]"
        assert title =~ "Deploy app"
        assert "proposed" in attrs.labels
        assert attrs.body =~ "sprite-001"
        assert attrs.body =~ "Deploy app"

        {:ok,
         %{
           number: 42,
           title: title,
           body: attrs.body,
           state: "open",
           labels: attrs.labels,
           comments: []
         }}
      end)

      assert {:ok, issue} =
               WorkProposal.propose_work("Deploy app", sprite_id: "sprite-001")

      assert issue.number == 42
      assert "proposed" in issue.labels
    end

    test "includes reason and context in the issue body" do
      Lattice.Capabilities.MockGitHub
      |> expect(:create_issue, fn _title, attrs ->
        assert attrs.body =~ "Need to update"
        assert attrs.body =~ "branch"
        assert attrs.body =~ "main"

        {:ok,
         %{
           number: 43,
           title: "[Sprite] Update",
           body: attrs.body,
           state: "open",
           labels: ["proposed"],
           comments: []
         }}
      end)

      assert {:ok, _issue} =
               WorkProposal.propose_work("Update",
                 sprite_id: "sprite-002",
                 reason: "Need to update",
                 context: %{branch: "main"}
               )
    end

    test "returns error when GitHub API fails" do
      Lattice.Capabilities.MockGitHub
      |> expect(:create_issue, fn _title, _attrs ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} =
               WorkProposal.propose_work("Fail", sprite_id: "sprite-003")
    end
  end

  describe "check_approval/1" do
    test "returns :approved when approved label is present" do
      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 ->
        {:ok, %{number: 42, labels: ["proposed", "approved"]}}
      end)

      assert {:ok, :approved} = WorkProposal.check_approval(42)
    end

    test "returns :pending when approved label is not present" do
      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 ->
        {:ok, %{number: 42, labels: ["proposed"]}}
      end)

      assert {:ok, :pending} = WorkProposal.check_approval(42)
    end

    test "returns error when issue cannot be fetched" do
      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 999 ->
        {:error, :not_found}
      end)

      assert {:error, :not_found} = WorkProposal.check_approval(999)
    end
  end

  describe "transition_label/3" do
    test "transitions between valid states" do
      Lattice.Capabilities.MockGitHub
      |> expect(:remove_label, fn 42, "proposed" ->
        {:ok, []}
      end)
      |> expect(:add_label, fn 42, "approved" ->
        {:ok, ["approved"]}
      end)

      assert {:ok, ["approved"]} = WorkProposal.transition_label(42, "proposed", "approved")
    end

    test "rejects invalid transitions without calling GitHub" do
      # No expectations set — should not call GitHub at all
      assert {:error, {:invalid_transition, "proposed", "done"}} =
               WorkProposal.transition_label(42, "proposed", "done")
    end

    test "returns error when remove_label fails" do
      Lattice.Capabilities.MockGitHub
      |> expect(:remove_label, fn 42, "proposed" ->
        {:error, :not_found}
      end)

      assert {:error, :not_found} = WorkProposal.transition_label(42, "proposed", "approved")
    end
  end

  describe "complete/3" do
    test "transitions to done and adds a comment" do
      Lattice.Capabilities.MockGitHub
      |> expect(:remove_label, fn 42, "in-progress" ->
        {:ok, []}
      end)
      |> expect(:add_label, fn 42, "done" ->
        {:ok, ["done"]}
      end)
      |> expect(:create_comment, fn 42, body ->
        assert body =~ "Completed"
        assert body =~ "Deployment successful"
        {:ok, %{id: 1, body: body, issue_number: 42}}
      end)

      assert {:ok, ["done"]} = WorkProposal.complete(42, "in-progress", "Deployment successful")
    end

    test "returns error for invalid transition" do
      assert {:error, {:invalid_transition, "proposed", "done"}} =
               WorkProposal.complete(42, "proposed", "Nope")
    end
  end
end
