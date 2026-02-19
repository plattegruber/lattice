defmodule Lattice.Capabilities.GitHub.ArtifactLinkTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.ArtifactLink

  describe "new/1" do
    test "creates a link with required fields" do
      link =
        ArtifactLink.new(%{
          intent_id: "int_abc",
          kind: :issue,
          ref: 42,
          role: :governance
        })

      assert link.intent_id == "int_abc"
      assert link.kind == :issue
      assert link.ref == 42
      assert link.role == :governance
      assert link.run_id == nil
      assert link.url == nil
      assert %DateTime{} = link.created_at
    end

    test "creates a link with all fields" do
      now = DateTime.utc_now()

      link =
        ArtifactLink.new(%{
          intent_id: "int_xyz",
          run_id: "run_001",
          kind: :pull_request,
          ref: 99,
          url: "https://github.com/owner/repo/pull/99",
          role: :output,
          created_at: now
        })

      assert link.intent_id == "int_xyz"
      assert link.run_id == "run_001"
      assert link.kind == :pull_request
      assert link.ref == 99
      assert link.url == "https://github.com/owner/repo/pull/99"
      assert link.role == :output
      assert link.created_at == now
    end

    test "raises on missing required field" do
      assert_raise KeyError, fn ->
        ArtifactLink.new(%{intent_id: "int_abc", kind: :issue})
      end
    end
  end
end
