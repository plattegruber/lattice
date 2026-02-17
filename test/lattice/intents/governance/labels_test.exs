defmodule Lattice.Intents.Governance.LabelsTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Intents.Governance.Labels

  describe "all/0" do
    test "returns all governance labels" do
      labels = Labels.all()
      assert "intent-awaiting-approval" in labels
      assert "intent-approved" in labels
      assert "intent-rejected" in labels
      assert length(labels) == 3
    end
  end

  describe "for_state/1" do
    test "maps awaiting_approval to its label" do
      assert {:ok, "intent-awaiting-approval"} = Labels.for_state(:awaiting_approval)
    end

    test "maps approved to its label" do
      assert {:ok, "intent-approved"} = Labels.for_state(:approved)
    end

    test "maps rejected to its label" do
      assert {:ok, "intent-rejected"} = Labels.for_state(:rejected)
    end

    test "returns error for states without labels" do
      assert {:error, :no_label} = Labels.for_state(:running)
      assert {:error, :no_label} = Labels.for_state(:completed)
      assert {:error, :no_label} = Labels.for_state(:proposed)
    end
  end

  describe "to_state/1" do
    test "maps intent-approved to :approved" do
      assert {:ok, :approved} = Labels.to_state("intent-approved")
    end

    test "maps intent-rejected to :rejected" do
      assert {:ok, :rejected} = Labels.to_state("intent-rejected")
    end

    test "returns error for unknown labels" do
      assert {:error, :unknown_label} = Labels.to_state("bug")
      assert {:error, :unknown_label} = Labels.to_state("intent-awaiting-approval")
    end
  end

  describe "valid?/1" do
    test "returns true for valid governance labels" do
      assert Labels.valid?("intent-awaiting-approval")
      assert Labels.valid?("intent-approved")
      assert Labels.valid?("intent-rejected")
    end

    test "returns false for invalid labels" do
      refute Labels.valid?("bug")
      refute Labels.valid?("proposed")
      refute Labels.valid?("approved")
    end
  end

  describe "accessor functions" do
    test "awaiting_approval/0" do
      assert Labels.awaiting_approval() == "intent-awaiting-approval"
    end

    test "approved/0" do
      assert Labels.approved() == "intent-approved"
    end

    test "rejected/0" do
      assert Labels.rejected() == "intent-rejected"
    end
  end
end
