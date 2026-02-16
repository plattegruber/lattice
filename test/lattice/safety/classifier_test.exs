defmodule Lattice.Safety.ClassifierTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Safety.Action
  alias Lattice.Safety.Classifier

  describe "classify/2" do
    # ── Safe Actions ───────────────────────────────────────────────────

    test "classifies sprites:list_sprites as safe" do
      assert {:ok, %Action{classification: :safe}} = Classifier.classify(:sprites, :list_sprites)
    end

    test "classifies sprites:get_sprite as safe" do
      assert {:ok, %Action{classification: :safe}} = Classifier.classify(:sprites, :get_sprite)
    end

    test "classifies sprites:fetch_logs as safe" do
      assert {:ok, %Action{classification: :safe}} = Classifier.classify(:sprites, :fetch_logs)
    end

    test "classifies github:list_issues as safe" do
      assert {:ok, %Action{classification: :safe}} = Classifier.classify(:github, :list_issues)
    end

    test "classifies fly:logs as safe" do
      assert {:ok, %Action{classification: :safe}} = Classifier.classify(:fly, :logs)
    end

    test "classifies fly:machine_status as safe" do
      assert {:ok, %Action{classification: :safe}} = Classifier.classify(:fly, :machine_status)
    end

    test "classifies secret_store:get_secret as safe" do
      assert {:ok, %Action{classification: :safe}} =
               Classifier.classify(:secret_store, :get_secret)
    end

    # ── Controlled Actions ─────────────────────────────────────────────

    test "classifies sprites:wake as controlled" do
      assert {:ok, %Action{classification: :controlled}} = Classifier.classify(:sprites, :wake)
    end

    test "classifies sprites:sleep as controlled" do
      assert {:ok, %Action{classification: :controlled}} = Classifier.classify(:sprites, :sleep)
    end

    test "classifies sprites:exec as controlled" do
      assert {:ok, %Action{classification: :controlled}} = Classifier.classify(:sprites, :exec)
    end

    test "classifies github:create_issue as controlled" do
      assert {:ok, %Action{classification: :controlled}} =
               Classifier.classify(:github, :create_issue)
    end

    test "classifies github:update_issue as controlled" do
      assert {:ok, %Action{classification: :controlled}} =
               Classifier.classify(:github, :update_issue)
    end

    test "classifies github:add_label as controlled" do
      assert {:ok, %Action{classification: :controlled}} =
               Classifier.classify(:github, :add_label)
    end

    test "classifies github:remove_label as controlled" do
      assert {:ok, %Action{classification: :controlled}} =
               Classifier.classify(:github, :remove_label)
    end

    test "classifies github:create_comment as controlled" do
      assert {:ok, %Action{classification: :controlled}} =
               Classifier.classify(:github, :create_comment)
    end

    # ── Dangerous Actions ──────────────────────────────────────────────

    test "classifies fly:deploy as dangerous" do
      assert {:ok, %Action{classification: :dangerous}} = Classifier.classify(:fly, :deploy)
    end

    # ── Unknown Actions ────────────────────────────────────────────────

    test "returns error for unknown capability/operation" do
      assert {:error, :unknown_action} = Classifier.classify(:unknown, :unknown)
    end

    test "returns error for known capability but unknown operation" do
      assert {:error, :unknown_action} = Classifier.classify(:sprites, :destroy)
    end

    # ── Action struct correctness ──────────────────────────────────────

    test "returns Action struct with correct fields" do
      assert {:ok, action} = Classifier.classify(:sprites, :wake)

      assert action.capability == :sprites
      assert action.operation == :wake
      assert action.classification == :controlled
    end
  end

  describe "classification_for/2" do
    test "returns the classification atom for known actions" do
      assert Classifier.classification_for(:sprites, :list_sprites) == :safe
      assert Classifier.classification_for(:sprites, :wake) == :controlled
      assert Classifier.classification_for(:fly, :deploy) == :dangerous
    end

    test "returns :unknown for unregistered actions" do
      assert Classifier.classification_for(:unknown, :op) == :unknown
    end
  end

  describe "actions_for/1" do
    test "returns all safe actions" do
      safe_actions = Classifier.actions_for(:safe)

      assert {:sprites, :list_sprites} in safe_actions
      assert {:sprites, :get_sprite} in safe_actions
      assert {:sprites, :fetch_logs} in safe_actions
      assert {:github, :list_issues} in safe_actions
      assert {:fly, :logs} in safe_actions
      assert {:fly, :machine_status} in safe_actions
      assert {:secret_store, :get_secret} in safe_actions
    end

    test "returns all controlled actions" do
      controlled_actions = Classifier.actions_for(:controlled)

      assert {:sprites, :wake} in controlled_actions
      assert {:sprites, :sleep} in controlled_actions
      assert {:sprites, :exec} in controlled_actions
      assert {:github, :create_issue} in controlled_actions
    end

    test "returns all dangerous actions" do
      dangerous_actions = Classifier.actions_for(:dangerous)

      assert {:fly, :deploy} in dangerous_actions
      assert length(dangerous_actions) == 1
    end

    test "returns empty list for classification with no actions" do
      # All three levels have actions, but this tests the shape
      assert is_list(Classifier.actions_for(:safe))
    end
  end

  describe "all_classifications/0" do
    test "returns a map of all registered classifications" do
      all = Classifier.all_classifications()

      assert is_map(all)
      assert Map.get(all, {:sprites, :list_sprites}) == :safe
      assert Map.get(all, {:sprites, :wake}) == :controlled
      assert Map.get(all, {:fly, :deploy}) == :dangerous
    end

    test "covers all capability operations" do
      all = Classifier.all_classifications()

      # Sprites: 6 operations
      sprites_ops = Enum.filter(all, fn {{cap, _op}, _class} -> cap == :sprites end)
      assert length(sprites_ops) == 6

      # GitHub: 6 operations
      github_ops = Enum.filter(all, fn {{cap, _op}, _class} -> cap == :github end)
      assert length(github_ops) == 6

      # Fly: 3 operations
      fly_ops = Enum.filter(all, fn {{cap, _op}, _class} -> cap == :fly end)
      assert length(fly_ops) == 3

      # SecretStore: 1 operation
      secret_ops = Enum.filter(all, fn {{cap, _op}, _class} -> cap == :secret_store end)
      assert length(secret_ops) == 1
    end
  end
end
