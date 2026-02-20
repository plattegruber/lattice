defmodule Lattice.Intents.KindTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Kind

  setup do
    Kind.init()
    :ok
  end

  # ── Registry ──────────────────────────────────────────────────────────

  describe "registry" do
    test "registered/0 includes all built-in kinds" do
      kinds = Kind.registered()
      assert :action in kinds
      assert :inquiry in kinds
      assert :maintenance in kinds
    end

    test "registered/0 includes extended kinds" do
      kinds = Kind.registered()
      assert :issue_triage in kinds
      assert :pr_fixup in kinds
      assert :pr_create in kinds
    end

    test "lookup/1 returns module for registered kind" do
      assert {:ok, Kind.Action} = Kind.lookup(:action)
      assert {:ok, Kind.IssueTriage} = Kind.lookup(:issue_triage)
    end

    test "lookup/1 returns error for unknown kind" do
      assert {:error, :unknown_kind} = Kind.lookup(:nonexistent)
    end

    test "all/0 returns metadata for each kind" do
      all = Kind.all()
      action = Enum.find(all, &(&1.name == :action))
      assert action.description == "Action"
      assert action.module == Kind.Action
    end

    test "valid?/1 returns true for registered kinds" do
      assert Kind.valid?(:action)
      assert Kind.valid?(:issue_triage)
      refute Kind.valid?(:nonexistent)
    end
  end

  # ── Custom kind registration ────────────────────────────────────────

  describe "register/1" do
    defmodule TestKind do
      @behaviour Kind

      @impl true
      def name, do: :test_custom

      @impl true
      def description, do: "Test Custom"

      @impl true
      def required_payload_fields, do: ["custom_field"]

      @impl true
      def default_classification, do: :dangerous
    end

    test "registers a custom kind" do
      Kind.register(TestKind)
      assert {:ok, TestKind} = Kind.lookup(:test_custom)
      assert :test_custom in Kind.registered()
    end
  end

  # ── Payload validation ──────────────────────────────────────────────

  describe "validate_payload/2" do
    test "returns :ok when all required fields present" do
      assert :ok =
               Kind.validate_payload(:action, %{"capability" => "fly", "operation" => "deploy"})
    end

    test "returns warning when required fields missing" do
      assert {:warn, missing} = Kind.validate_payload(:action, %{"capability" => "fly"})
      assert "operation" in missing
    end

    test "returns :ok for maintenance (no required fields)" do
      assert :ok = Kind.validate_payload(:maintenance, %{})
    end

    test "returns :ok for unknown kind" do
      assert :ok = Kind.validate_payload(:completely_unknown, %{"anything" => true})
    end

    test "validates issue_triage requires issue_url" do
      assert {:warn, ["issue_url"]} = Kind.validate_payload(:issue_triage, %{})

      assert :ok =
               Kind.validate_payload(:issue_triage, %{"issue_url" => "https://github.com/..."})
    end

    test "validates pr_fixup requires pr_url and feedback" do
      assert {:warn, missing} = Kind.validate_payload(:pr_fixup, %{})
      assert "pr_url" in missing
      assert "feedback" in missing
    end

    test "validates pr_create requires repo and branch" do
      assert {:warn, missing} = Kind.validate_payload(:pr_create, %{})
      assert "repo" in missing
      assert "branch" in missing
    end
  end

  # ── Default classification ──────────────────────────────────────────

  describe "default_classification/1" do
    test "returns correct defaults for built-in kinds" do
      assert {:ok, :controlled} = Kind.default_classification(:action)
      assert {:ok, :controlled} = Kind.default_classification(:inquiry)
      assert {:ok, :safe} = Kind.default_classification(:maintenance)
    end

    test "returns correct defaults for extended kinds" do
      assert {:ok, :controlled} = Kind.default_classification(:issue_triage)
      assert {:ok, :controlled} = Kind.default_classification(:pr_fixup)
      assert {:ok, :controlled} = Kind.default_classification(:pr_create)
    end

    test "returns error for unknown kind" do
      assert {:error, :unknown_kind} = Kind.default_classification(:nonexistent)
    end
  end

  # ── Kind behaviour in Intent constructors ──────────────────────────

  describe "Intent.new/3 with extended kinds" do
    test "creates intent with issue_triage kind" do
      {:ok, intent} =
        Intent.new(:issue_triage, %{type: :webhook, id: "gh-123"},
          summary: "Triage issue #42",
          payload: %{"issue_url" => "https://github.com/org/repo/issues/42"}
        )

      assert intent.kind == :issue_triage
      assert intent.state == :proposed
    end

    test "creates intent with pr_fixup kind" do
      {:ok, intent} =
        Intent.new(:pr_fixup, %{type: :webhook, id: "gh-456"},
          summary: "Fix PR #10 review comments",
          payload: %{"pr_url" => "https://github.com/org/repo/pull/10", "feedback" => "fix typo"}
        )

      assert intent.kind == :pr_fixup
    end

    test "creates intent with pr_create kind" do
      {:ok, intent} =
        Intent.new(:pr_create, %{type: :agent, id: "agent-1"},
          summary: "Create PR from plan",
          payload: %{"repo" => "org/repo", "branch" => "feat/new-feature"}
        )

      assert intent.kind == :pr_create
    end

    test "logs warning for missing recommended fields" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          {:ok, _intent} =
            Intent.new(:issue_triage, %{type: :webhook, id: "gh-789"},
              summary: "Triage without URL",
              payload: %{"other" => "data"}
            )
        end)

      assert log =~ "missing recommended payload fields"
      assert log =~ "issue_url"
    end

    test "Intent.registered_kinds/0 returns all kinds" do
      kinds = Intent.registered_kinds()
      assert :action in kinds
      assert :issue_triage in kinds
      assert :pr_fixup in kinds
      assert :pr_create in kinds
    end
  end

  # ── Kind modules ───────────────────────────────────────────────────

  describe "built-in kind modules" do
    test "Action kind" do
      assert Kind.Action.name() == :action
      assert Kind.Action.description() == "Action"
      assert Kind.Action.default_classification() == :controlled
      assert Kind.Action.required_payload_fields() == ["capability", "operation"]
    end

    test "Inquiry kind" do
      assert Kind.Inquiry.name() == :inquiry
      assert Kind.Inquiry.description() == "Inquiry"
      assert Kind.Inquiry.default_classification() == :controlled
    end

    test "Maintenance kind" do
      assert Kind.Maintenance.name() == :maintenance
      assert Kind.Maintenance.default_classification() == :safe
      assert Kind.Maintenance.required_payload_fields() == []
    end

    test "IssueTriage kind" do
      assert Kind.IssueTriage.name() == :issue_triage
      assert Kind.IssueTriage.description() == "Issue Triage"
      assert Kind.IssueTriage.default_classification() == :controlled
      assert Kind.IssueTriage.required_payload_fields() == ["issue_url"]
    end

    test "PrFixup kind" do
      assert Kind.PrFixup.name() == :pr_fixup
      assert Kind.PrFixup.description() == "PR Fixup"
      assert Kind.PrFixup.required_payload_fields() == ["pr_url", "feedback"]
    end

    test "PrCreate kind" do
      assert Kind.PrCreate.name() == :pr_create
      assert Kind.PrCreate.description() == "PR Create"
      assert Kind.PrCreate.required_payload_fields() == ["repo", "branch"]
    end
  end
end
