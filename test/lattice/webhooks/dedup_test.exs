defmodule Lattice.Webhooks.DedupTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Webhooks.Dedup

  setup do
    Dedup.reset()
    :ok
  end

  describe "seen?/1" do
    test "returns false for new delivery ID" do
      refute Dedup.seen?("delivery-001")
    end

    test "returns true for previously seen delivery ID" do
      refute Dedup.seen?("delivery-002")
      assert Dedup.seen?("delivery-002")
    end

    test "different delivery IDs are tracked independently" do
      refute Dedup.seen?("delivery-a")
      refute Dedup.seen?("delivery-b")
      assert Dedup.seen?("delivery-a")
      assert Dedup.seen?("delivery-b")
    end
  end

  describe "reset/0" do
    test "clears all tracked delivery IDs" do
      Dedup.seen?("delivery-x")
      assert Dedup.seen?("delivery-x")

      Dedup.reset()

      refute Dedup.seen?("delivery-x")
    end
  end
end
