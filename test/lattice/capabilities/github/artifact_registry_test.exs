defmodule Lattice.Capabilities.GitHub.ArtifactRegistryTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.ArtifactLink
  alias Lattice.Capabilities.GitHub.ArtifactRegistry

  # The ArtifactRegistry is started by the application supervision tree.
  # Tests use the already-running instance. We clean up after each test
  # by tracking what we register and verifying in isolation by intent_id.

  describe "register/1 and lookup_by_intent/1" do
    test "registers a link and looks it up by intent_id" do
      link =
        ArtifactLink.new(%{
          intent_id: "int_reg_test_1",
          kind: :issue,
          ref: 100,
          role: :governance,
          url: "https://github.com/owner/repo/issues/100"
        })

      assert {:ok, ^link} = ArtifactRegistry.register(link)
      assert [^link] = ArtifactRegistry.lookup_by_intent("int_reg_test_1")
    end

    test "returns empty list for unknown intent" do
      assert [] = ArtifactRegistry.lookup_by_intent("int_nonexistent_xyz")
    end

    test "registers multiple links for the same intent" do
      link1 =
        ArtifactLink.new(%{
          intent_id: "int_reg_test_multi",
          kind: :issue,
          ref: 200,
          role: :governance
        })

      link2 =
        ArtifactLink.new(%{
          intent_id: "int_reg_test_multi",
          kind: :pull_request,
          ref: 201,
          role: :output,
          run_id: "run_001"
        })

      ArtifactRegistry.register(link1)
      ArtifactRegistry.register(link2)

      results = ArtifactRegistry.lookup_by_intent("int_reg_test_multi")
      assert length(results) == 2
      assert Enum.any?(results, &(&1.kind == :issue))
      assert Enum.any?(results, &(&1.kind == :pull_request))
    end
  end

  describe "lookup_by_ref/2 (reverse lookup)" do
    test "looks up links by kind and ref" do
      link =
        ArtifactLink.new(%{
          intent_id: "int_rev_test_1",
          kind: :pull_request,
          ref: 300,
          role: :output
        })

      ArtifactRegistry.register(link)

      results = ArtifactRegistry.lookup_by_ref(:pull_request, 300)
      assert Enum.any?(results, &(&1.intent_id == "int_rev_test_1"))
    end

    test "returns empty for unknown ref" do
      assert [] = ArtifactRegistry.lookup_by_ref(:issue, 999_999)
    end

    test "supports branch lookups by name" do
      link =
        ArtifactLink.new(%{
          intent_id: "int_branch_test",
          kind: :branch,
          ref: "feat/my-feature",
          role: :output
        })

      ArtifactRegistry.register(link)

      results = ArtifactRegistry.lookup_by_ref(:branch, "feat/my-feature")
      assert Enum.any?(results, &(&1.intent_id == "int_branch_test"))
    end

    test "supports commit lookups by SHA" do
      link =
        ArtifactLink.new(%{
          intent_id: "int_commit_test",
          kind: :commit,
          ref: "abc123def456",
          role: :output
        })

      ArtifactRegistry.register(link)

      results = ArtifactRegistry.lookup_by_ref(:commit, "abc123def456")
      assert Enum.any?(results, &(&1.intent_id == "int_commit_test"))
    end
  end

  describe "lookup_by_run/1" do
    test "looks up links by run_id" do
      link =
        ArtifactLink.new(%{
          intent_id: "int_run_test_1",
          run_id: "run_unique_test_1",
          kind: :pull_request,
          ref: 400,
          role: :output
        })

      ArtifactRegistry.register(link)

      results = ArtifactRegistry.lookup_by_run("run_unique_test_1")
      assert Enum.any?(results, &(&1.intent_id == "int_run_test_1"))
    end

    test "returns empty for unknown run_id" do
      assert [] = ArtifactRegistry.lookup_by_run("run_nonexistent_xyz")
    end

    test "skips run index when run_id is nil" do
      link =
        ArtifactLink.new(%{
          intent_id: "int_no_run_test",
          kind: :issue,
          ref: 500,
          role: :governance
        })

      ArtifactRegistry.register(link)

      # The nil run_id should not appear in any run lookup
      assert [] = ArtifactRegistry.lookup_by_run("nil")
    end
  end

  describe "telemetry" do
    test "emits [:lattice, :artifact, :registered] on register" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:lattice, :artifact, :registered]
        ])

      link =
        ArtifactLink.new(%{
          intent_id: "int_telemetry_test",
          kind: :issue,
          ref: 600,
          role: :governance
        })

      ArtifactRegistry.register(link)

      assert_receive {[:lattice, :artifact, :registered], ^ref, %{count: 1},
                      %{kind: :issue, role: :governance, intent_id: "int_telemetry_test"}}
    end
  end

  describe "all/1" do
    test "returns all registered links" do
      # Register at least one unique link
      link =
        ArtifactLink.new(%{
          intent_id: "int_all_test",
          kind: :issue,
          ref: 700,
          role: :governance
        })

      ArtifactRegistry.register(link)

      all = ArtifactRegistry.all()
      assert is_list(all)
      assert Enum.any?(all, &(&1.intent_id == "int_all_test"))
    end
  end
end
