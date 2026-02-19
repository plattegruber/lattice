defmodule Lattice.Policy.RepoProfileTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Policy.RepoProfile

  setup do
    # Clean up any test profiles
    {:ok, profiles} = RepoProfile.list()

    for p <- profiles, String.starts_with?(p.repo || "", "test/") do
      RepoProfile.delete(p.repo)
    end

    :ok
  end

  describe "put/1 and get/1" do
    test "stores and retrieves a profile" do
      profile = %RepoProfile{
        repo: "test/my-repo",
        test_commands: ["mix test"],
        ci_checks: ["build", "lint"],
        risk_zones: ["lib/safety/"]
      }

      assert :ok = RepoProfile.put(profile)
      assert {:ok, retrieved} = RepoProfile.get("test/my-repo")
      assert retrieved.repo == "test/my-repo"
      assert retrieved.test_commands == ["mix test"]
      assert retrieved.ci_checks == ["build", "lint"]
      assert retrieved.risk_zones == ["lib/safety/"]
    after
      RepoProfile.delete("test/my-repo")
    end

    test "returns error for missing profile" do
      assert {:error, :not_found} = RepoProfile.get("test/nonexistent")
    end

    test "overwrites existing profile" do
      profile1 = %RepoProfile{repo: "test/overwrite", test_commands: ["npm test"]}
      profile2 = %RepoProfile{repo: "test/overwrite", test_commands: ["yarn test"]}

      RepoProfile.put(profile1)
      RepoProfile.put(profile2)

      {:ok, retrieved} = RepoProfile.get("test/overwrite")
      assert retrieved.test_commands == ["yarn test"]
    after
      RepoProfile.delete("test/overwrite")
    end
  end

  describe "list/0" do
    test "lists all profiles" do
      RepoProfile.put(%RepoProfile{repo: "test/list-a"})
      RepoProfile.put(%RepoProfile{repo: "test/list-b"})

      {:ok, profiles} = RepoProfile.list()
      repos = Enum.map(profiles, & &1.repo)
      assert "test/list-a" in repos
      assert "test/list-b" in repos
    after
      RepoProfile.delete("test/list-a")
      RepoProfile.delete("test/list-b")
    end

    test "returns profiles sorted by repo" do
      RepoProfile.put(%RepoProfile{repo: "test/z-repo"})
      RepoProfile.put(%RepoProfile{repo: "test/a-repo"})

      {:ok, profiles} = RepoProfile.list()
      test_profiles = Enum.filter(profiles, &String.starts_with?(&1.repo || "", "test/"))
      repos = Enum.map(test_profiles, & &1.repo)
      assert repos == Enum.sort(repos)
    after
      RepoProfile.delete("test/z-repo")
      RepoProfile.delete("test/a-repo")
    end
  end

  describe "delete/1" do
    test "removes a profile" do
      RepoProfile.put(%RepoProfile{repo: "test/delete-me"})
      assert {:ok, _} = RepoProfile.get("test/delete-me")

      RepoProfile.delete("test/delete-me")
      assert {:error, :not_found} = RepoProfile.get("test/delete-me")
    end
  end

  describe "get_or_default/1" do
    test "returns existing profile" do
      RepoProfile.put(%RepoProfile{repo: "test/exists", test_commands: ["make test"]})

      profile = RepoProfile.get_or_default("test/exists")
      assert profile.test_commands == ["make test"]
    after
      RepoProfile.delete("test/exists")
    end

    test "returns default profile for unknown repo" do
      profile = RepoProfile.get_or_default("test/unknown")
      assert profile.repo == "test/unknown"
      assert profile.test_commands == []
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips through map" do
      profile = %RepoProfile{
        repo: "test/roundtrip",
        test_commands: ["mix test --only unit"],
        branch_convention: %{main: "main", pr_prefix: "feat/"},
        ci_checks: ["ci"],
        risk_zones: ["config/"],
        doc_paths: ["docs/"],
        auto_approve_paths: ["README.md"],
        settings: %{max_pr_size: 500}
      }

      map = RepoProfile.to_map(profile)
      restored = RepoProfile.from_map(map)

      assert restored.repo == profile.repo
      assert restored.test_commands == profile.test_commands
      assert restored.risk_zones == profile.risk_zones
      assert restored.auto_approve_paths == profile.auto_approve_paths
      assert restored.settings == profile.settings
    end
  end
end
