defmodule Lattice.Capabilities.GitHub.LabelsTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.Labels

  describe "all/0" do
    test "returns all five HITL labels" do
      labels = Labels.all()

      assert length(labels) == 5
      assert "proposed" in labels
      assert "approved" in labels
      assert "in-progress" in labels
      assert "blocked" in labels
      assert "done" in labels
    end
  end

  describe "valid?/1" do
    test "returns true for valid labels" do
      for label <- Labels.all() do
        assert Labels.valid?(label), "expected #{label} to be valid"
      end
    end

    test "returns false for invalid labels" do
      refute Labels.valid?("invalid")
      refute Labels.valid?("open")
      refute Labels.valid?("")
    end
  end

  describe "valid_transitions/1" do
    test "proposed can transition to approved or blocked" do
      assert {:ok, transitions} = Labels.valid_transitions("proposed")
      assert "approved" in transitions
      assert "blocked" in transitions
      assert length(transitions) == 2
    end

    test "approved can transition to in-progress or blocked" do
      assert {:ok, transitions} = Labels.valid_transitions("approved")
      assert "in-progress" in transitions
      assert "blocked" in transitions
      assert length(transitions) == 2
    end

    test "in-progress can transition to done or blocked" do
      assert {:ok, transitions} = Labels.valid_transitions("in-progress")
      assert "done" in transitions
      assert "blocked" in transitions
      assert length(transitions) == 2
    end

    test "blocked can transition to proposed or approved" do
      assert {:ok, transitions} = Labels.valid_transitions("blocked")
      assert "proposed" in transitions
      assert "approved" in transitions
      assert length(transitions) == 2
    end

    test "done has no valid transitions (terminal)" do
      assert {:ok, []} = Labels.valid_transitions("done")
    end

    test "returns error for unknown labels" do
      assert {:error, :unknown_label} = Labels.valid_transitions("invalid")
    end
  end

  describe "validate_transition/2" do
    test "allows valid forward transitions" do
      assert :ok = Labels.validate_transition("proposed", "approved")
      assert :ok = Labels.validate_transition("approved", "in-progress")
      assert :ok = Labels.validate_transition("in-progress", "done")
    end

    test "allows transitions to blocked" do
      assert :ok = Labels.validate_transition("proposed", "blocked")
      assert :ok = Labels.validate_transition("approved", "blocked")
      assert :ok = Labels.validate_transition("in-progress", "blocked")
    end

    test "allows recovery from blocked" do
      assert :ok = Labels.validate_transition("blocked", "proposed")
      assert :ok = Labels.validate_transition("blocked", "approved")
    end

    test "rejects skipping states" do
      assert {:error, {:invalid_transition, "proposed", "done"}} =
               Labels.validate_transition("proposed", "done")

      assert {:error, {:invalid_transition, "proposed", "in-progress"}} =
               Labels.validate_transition("proposed", "in-progress")
    end

    test "rejects backward transitions (except from blocked)" do
      assert {:error, {:invalid_transition, "approved", "proposed"}} =
               Labels.validate_transition("approved", "proposed")

      assert {:error, {:invalid_transition, "in-progress", "approved"}} =
               Labels.validate_transition("in-progress", "approved")

      assert {:error, {:invalid_transition, "done", "proposed"}} =
               Labels.validate_transition("done", "proposed")
    end

    test "rejects transitions from unknown labels" do
      assert {:error, {:invalid_transition, "invalid", "proposed"}} =
               Labels.validate_transition("invalid", "proposed")
    end

    test "rejects transitions from done" do
      for target <- Labels.all(), target != "done" do
        assert {:error, {:invalid_transition, "done", ^target}} =
                 Labels.validate_transition("done", target)
      end
    end
  end

  describe "terminal?/1" do
    test "done is terminal" do
      assert Labels.terminal?("done")
    end

    test "other labels are not terminal" do
      for label <- ["proposed", "approved", "in-progress", "blocked"] do
        refute Labels.terminal?(label), "expected #{label} to not be terminal"
      end
    end
  end

  describe "initial/0" do
    test "returns proposed" do
      assert Labels.initial() == "proposed"
    end
  end
end
