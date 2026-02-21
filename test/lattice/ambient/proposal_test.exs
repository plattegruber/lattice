defmodule Lattice.Ambient.ProposalTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Ambient.Proposal

  @valid_json Jason.encode!(%{
                "protocol_version" => "bundle-v1",
                "status" => "ready",
                "repo" => "plattegruber/lattice",
                "base_branch" => "main",
                "work_branch" => "sprite/fix-cache-key",
                "bundle_path" => ".lattice/out/change.bundle",
                "patch_path" => ".lattice/out/diff.patch",
                "summary" => "Fixed the cache key bug",
                "pr" => %{
                  "title" => "Fix cache key collision",
                  "body" => "Resolves the cache key collision issue",
                  "labels" => ["lattice:ambient"],
                  "review_notes" => []
                },
                "commands" => [
                  %{"cmd" => "mix format", "exit" => 0},
                  %{"cmd" => "mix test", "exit" => 0}
                ],
                "flags" => %{
                  "touches_migrations" => false,
                  "touches_deps" => false,
                  "touches_auth" => false,
                  "touches_secrets" => false
                }
              })

  describe "from_json/1" do
    test "parses valid JSON into a Proposal struct" do
      assert {:ok, proposal} = Proposal.from_json(@valid_json)
      assert proposal.protocol_version == "bundle-v1"
      assert proposal.status == "ready"
      assert proposal.repo == "plattegruber/lattice"
      assert proposal.base_branch == "main"
      assert proposal.work_branch == "sprite/fix-cache-key"
      assert proposal.bundle_path == ".lattice/out/change.bundle"
      assert proposal.patch_path == ".lattice/out/diff.patch"
      assert proposal.summary == "Fixed the cache key bug"
      assert proposal.pr["title"] == "Fix cache key collision"
      assert length(proposal.commands) == 2
      assert proposal.flags["touches_deps"] == false
    end

    test "returns error for missing required fields" do
      json = Jason.encode!(%{"protocol_version" => "bundle-v1", "status" => "ready"})
      assert {:error, {:missing_fields, missing}} = Proposal.from_json(json)
      assert "base_branch" in missing
      assert "work_branch" in missing
      assert "bundle_path" in missing
    end

    test "returns error for unknown protocol_version" do
      json =
        Jason.encode!(%{
          "protocol_version" => "unknown-v99",
          "status" => "ready",
          "base_branch" => "main",
          "work_branch" => "sprite/foo",
          "bundle_path" => ".lattice/out/change.bundle"
        })

      assert {:error, {:unknown_protocol, "unknown-v99"}} = Proposal.from_json(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, :invalid_json} = Proposal.from_json("not json at all")
    end

    test "returns error for non-object JSON" do
      assert {:error, :invalid_json_structure} = Proposal.from_json("[1, 2, 3]")
    end

    test "returns error for non-binary input" do
      assert {:error, :invalid_input} = Proposal.from_json(42)
    end

    test "parses no_changes status" do
      json =
        Jason.encode!(%{
          "protocol_version" => "bundle-v1",
          "status" => "no_changes",
          "base_branch" => "main",
          "work_branch" => "sprite/foo",
          "bundle_path" => ".lattice/out/change.bundle"
        })

      assert {:ok, proposal} = Proposal.from_json(json)
      assert proposal.status == "no_changes"
    end

    test "parses blocked status with reason" do
      json =
        Jason.encode!(%{
          "protocol_version" => "bundle-v1",
          "status" => "blocked",
          "blocked_reason" => "Cannot find the relevant module",
          "base_branch" => "main",
          "work_branch" => "sprite/foo",
          "bundle_path" => ".lattice/out/change.bundle"
        })

      assert {:ok, proposal} = Proposal.from_json(json)
      assert proposal.status == "blocked"
      assert proposal.blocked_reason == "Cannot find the relevant module"
    end

    test "defaults pr, commands, and flags to empty values" do
      json =
        Jason.encode!(%{
          "protocol_version" => "bundle-v1",
          "status" => "ready",
          "base_branch" => "main",
          "work_branch" => "sprite/foo",
          "bundle_path" => ".lattice/out/change.bundle"
        })

      assert {:ok, proposal} = Proposal.from_json(json)
      assert proposal.pr == %{}
      assert proposal.commands == []
      assert proposal.flags == %{}
    end
  end

  describe "ready?/1" do
    test "returns true for ready status" do
      assert {:ok, proposal} = Proposal.from_json(@valid_json)
      assert Proposal.ready?(proposal)
    end

    test "returns false for non-ready status" do
      json =
        Jason.encode!(%{
          "protocol_version" => "bundle-v1",
          "status" => "blocked",
          "base_branch" => "main",
          "work_branch" => "sprite/foo",
          "bundle_path" => ".lattice/out/change.bundle"
        })

      assert {:ok, proposal} = Proposal.from_json(json)
      refute Proposal.ready?(proposal)
    end
  end
end
