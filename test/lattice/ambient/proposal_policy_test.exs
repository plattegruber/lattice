defmodule Lattice.Ambient.ProposalPolicyTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.Ambient.Proposal
  alias Lattice.Ambient.ProposalPolicy

  defp base_proposal(overrides \\ %{}) do
    defaults = %{
      protocol_version: "bundle-v1",
      status: "ready",
      base_branch: "main",
      work_branch: "sprite/foo",
      bundle_path: ".lattice/out/change.bundle",
      pr: %{},
      commands: [],
      flags: %{}
    }

    struct!(Proposal, Map.merge(defaults, overrides))
  end

  describe "check/2 with clean diff" do
    test "returns ok with no warnings for safe files" do
      proposal = base_proposal()
      diff_names = ["lib/lattice/ambient/foo.ex", "test/lattice/ambient/foo_test.exs"]

      assert {:ok, []} = ProposalPolicy.check(proposal, diff_names)
    end
  end

  describe "check/2 with forbidden patterns" do
    test "rejects .env files" do
      proposal = base_proposal()
      diff_names = ["lib/foo.ex", ".env"]

      assert {:error, :policy_violation} = ProposalPolicy.check(proposal, diff_names)
    end

    test "rejects .env.production files" do
      proposal = base_proposal()
      diff_names = [".env.production"]

      assert {:error, :policy_violation} = ProposalPolicy.check(proposal, diff_names)
    end

    test "rejects .pem files" do
      proposal = base_proposal()
      diff_names = ["certs/server.pem"]

      assert {:error, :policy_violation} = ProposalPolicy.check(proposal, diff_names)
    end

    test "rejects .key files" do
      proposal = base_proposal()
      diff_names = ["certs/private.key"]

      assert {:error, :policy_violation} = ProposalPolicy.check(proposal, diff_names)
    end

    test "rejects credentials files" do
      proposal = base_proposal()
      diff_names = ["config/credentials.json"]

      assert {:error, :policy_violation} = ProposalPolicy.check(proposal, diff_names)
    end

    test "rejects secrets.yml" do
      proposal = base_proposal()
      diff_names = ["config/secrets.yml"]

      assert {:error, :policy_violation} = ProposalPolicy.check(proposal, diff_names)
    end
  end

  describe "check/2 warnings" do
    test "warns when touches_deps flag and mix.exs changed" do
      proposal = base_proposal(%{flags: %{"touches_deps" => true}})
      diff_names = ["mix.exs", "lib/foo.ex"]

      assert {:ok, warnings} = ProposalPolicy.check(proposal, diff_names)
      assert Enum.any?(warnings, &String.contains?(&1, "dependencies"))
    end

    test "no dep warning when touches_deps but mix.exs not in diff" do
      proposal = base_proposal(%{flags: %{"touches_deps" => true}})
      diff_names = ["lib/foo.ex"]

      assert {:ok, []} = ProposalPolicy.check(proposal, diff_names)
    end

    test "warns when touches_migrations and migration files present" do
      proposal = base_proposal(%{flags: %{"touches_migrations" => true}})
      diff_names = ["priv/repo/migrations/20260220_add_users.exs"]

      assert {:ok, warnings} = ProposalPolicy.check(proposal, diff_names)
      assert Enum.any?(warnings, &String.contains?(&1, "migrations"))
    end

    test "warns when touches_auth flag is set" do
      proposal = base_proposal(%{flags: %{"touches_auth" => true}})
      diff_names = ["lib/foo.ex"]

      assert {:ok, warnings} = ProposalPolicy.check(proposal, diff_names)
      assert Enum.any?(warnings, &String.contains?(&1, "authentication"))
    end

    test "warns about failed commands" do
      proposal =
        base_proposal(%{
          commands: [
            %{"cmd" => "mix format", "exit" => 0},
            %{"cmd" => "mix test", "exit" => 1}
          ]
        })

      diff_names = ["lib/foo.ex"]

      assert {:ok, warnings} = ProposalPolicy.check(proposal, diff_names)
      assert Enum.any?(warnings, &String.contains?(&1, "non-zero"))
    end
  end
end
