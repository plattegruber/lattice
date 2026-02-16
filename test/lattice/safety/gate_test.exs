defmodule Lattice.Safety.GateTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Safety.Action
  alias Lattice.Safety.Gate

  # Helper to temporarily set guardrails config for a test
  defp with_guardrails(config, fun) do
    previous = Application.get_env(:lattice, :guardrails, [])
    Application.put_env(:lattice, :guardrails, config)

    try do
      fun.()
    after
      Application.put_env(:lattice, :guardrails, previous)
    end
  end

  defp safe_action do
    {:ok, action} = Action.new(:sprites, :list_sprites, :safe)
    action
  end

  defp controlled_action do
    {:ok, action} = Action.new(:sprites, :wake, :controlled)
    action
  end

  defp dangerous_action do
    {:ok, action} = Action.new(:fly, :deploy, :dangerous)
    action
  end

  # ── check/1 ────────────────────────────────────────────────────────

  describe "check/1 with safe actions" do
    test "always allows safe actions" do
      assert Gate.check(safe_action()) == :allow
    end

    test "allows safe actions even when all guardrails are restrictive" do
      with_guardrails(
        [allow_controlled: false, allow_dangerous: false, require_approval_for_controlled: true],
        fn ->
          assert Gate.check(safe_action()) == :allow
        end
      )
    end
  end

  describe "check/1 with controlled actions" do
    test "denies when allow_controlled is false" do
      with_guardrails([allow_controlled: false], fn ->
        assert Gate.check(controlled_action()) == {:deny, :action_not_permitted}
      end)
    end

    test "requires approval when allow_controlled is true and require_approval is true" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          assert Gate.check(controlled_action()) == {:deny, :approval_required}
        end
      )
    end

    test "allows when allow_controlled is true and require_approval is false" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: false],
        fn ->
          assert Gate.check(controlled_action()) == :allow
        end
      )
    end

    test "defaults allow_controlled to true when not configured" do
      with_guardrails([], fn ->
        # Default: allowed but requires approval
        assert Gate.check(controlled_action()) == {:deny, :approval_required}
      end)
    end

    test "defaults require_approval_for_controlled to true when not configured" do
      with_guardrails([allow_controlled: true], fn ->
        assert Gate.check(controlled_action()) == {:deny, :approval_required}
      end)
    end
  end

  describe "check/1 with dangerous actions" do
    test "denies when allow_dangerous is false" do
      with_guardrails([allow_dangerous: false], fn ->
        assert Gate.check(dangerous_action()) == {:deny, :action_not_permitted}
      end)
    end

    test "requires approval even when allow_dangerous is true" do
      with_guardrails([allow_dangerous: true], fn ->
        assert Gate.check(dangerous_action()) == {:deny, :approval_required}
      end)
    end

    test "defaults allow_dangerous to false when not configured" do
      with_guardrails([], fn ->
        assert Gate.check(dangerous_action()) == {:deny, :action_not_permitted}
      end)
    end
  end

  # ── check_with_approval/2 ──────────────────────────────────────────

  describe "check_with_approval/2" do
    test "allows safe actions regardless of approval status" do
      assert Gate.check_with_approval(safe_action(), approved: false) == :allow
      assert Gate.check_with_approval(safe_action(), approved: true) == :allow
    end

    test "allows controlled action with approval when config permits" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          assert Gate.check_with_approval(controlled_action(), approved: true) == :allow
        end
      )
    end

    test "denies controlled action without approval when approval is required" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          assert Gate.check_with_approval(controlled_action(), approved: false) ==
                   {:deny, :approval_required}
        end
      )
    end

    test "denies controlled action even with approval when allow_controlled is false" do
      with_guardrails([allow_controlled: false], fn ->
        assert Gate.check_with_approval(controlled_action(), approved: true) ==
                 {:deny, :action_not_permitted}
      end)
    end

    test "allows dangerous action with approval and config opt-in" do
      with_guardrails([allow_dangerous: true], fn ->
        assert Gate.check_with_approval(dangerous_action(), approved: true) == :allow
      end)
    end

    test "denies dangerous action without approval even with config opt-in" do
      with_guardrails([allow_dangerous: true], fn ->
        assert Gate.check_with_approval(dangerous_action(), approved: false) ==
                 {:deny, :approval_required}
      end)
    end

    test "denies dangerous action with approval but without config opt-in" do
      with_guardrails([allow_dangerous: false], fn ->
        assert Gate.check_with_approval(dangerous_action(), approved: true) ==
                 {:deny, :action_not_permitted}
      end)
    end
  end

  # ── requires_approval?/1 ───────────────────────────────────────────

  describe "requires_approval?/1" do
    test "returns false for safe actions" do
      assert Gate.requires_approval?(safe_action()) == false
    end

    test "returns true for controlled actions when approval is required" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          assert Gate.requires_approval?(controlled_action()) == true
        end
      )
    end

    test "returns false for controlled actions when approval is not required" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: false],
        fn ->
          assert Gate.requires_approval?(controlled_action()) == false
        end
      )
    end

    test "returns false for controlled actions when category is disabled" do
      with_guardrails([allow_controlled: false], fn ->
        # Not approval_required, but action_not_permitted
        assert Gate.requires_approval?(controlled_action()) == false
      end)
    end

    test "returns true for dangerous actions when config opts in" do
      with_guardrails([allow_dangerous: true], fn ->
        assert Gate.requires_approval?(dangerous_action()) == true
      end)
    end

    test "returns false for dangerous actions when config does not opt in" do
      with_guardrails([allow_dangerous: false], fn ->
        # Not approval_required, but action_not_permitted
        assert Gate.requires_approval?(dangerous_action()) == false
      end)
    end
  end
end
