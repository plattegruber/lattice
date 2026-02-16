defmodule Lattice.Events.ApprovalNeededTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Events.ApprovalNeeded

  describe "new/4" do
    test "creates an approval needed event with required fields" do
      assert {:ok, event} = ApprovalNeeded.new("sprite-001", "deploy to prod", :dangerous)

      assert event.sprite_id == "sprite-001"
      assert event.action == "deploy to prod"
      assert event.classification == :dangerous
      assert event.context == %{}
      assert %DateTime{} = event.timestamp
    end

    test "accepts optional context" do
      context = %{branch: "main", commit: "abc123"}

      assert {:ok, event} =
               ApprovalNeeded.new("sprite-001", "force push", :dangerous, context: context)

      assert event.context == context
    end

    test "accepts optional timestamp" do
      ts = ~U[2026-01-15 10:00:00Z]

      assert {:ok, event} =
               ApprovalNeeded.new("sprite-001", "delete file", :needs_review, timestamp: ts)

      assert event.timestamp == ts
    end

    test "accepts all valid classifications" do
      for classification <- [:needs_review, :dangerous] do
        assert {:ok, _event} = ApprovalNeeded.new("sprite-001", "action", classification)
      end
    end

    test "rejects invalid classification" do
      assert {:error, {:invalid_classification, :safe}} =
               ApprovalNeeded.new("sprite-001", "action", :safe)
    end

    test "returns valid classifications through valid_classifications/0" do
      assert ApprovalNeeded.valid_classifications() == [:needs_review, :dangerous]
    end
  end
end
