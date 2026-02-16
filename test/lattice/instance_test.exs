defmodule Lattice.InstanceTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Instance

  # ── Identity ──────────────────────────────────────────────────────

  describe "name/0" do
    test "returns the configured instance name" do
      assert is_binary(Instance.name())
    end

    test "returns default when no config is set" do
      original = Application.get_env(:lattice, :instance)
      Application.put_env(:lattice, :instance, [])

      assert Instance.name() == "unknown"

      Application.put_env(:lattice, :instance, original)
    end
  end

  describe "environment/0" do
    test "returns the configured environment as an atom" do
      assert is_atom(Instance.environment())
    end
  end

  describe "resources/0" do
    test "returns a keyword list of resource bindings" do
      resources = Instance.resources()
      assert is_list(resources)
    end
  end

  describe "resource/1" do
    test "returns nil for unconfigured resources" do
      # In test, resources may not be set
      result = Instance.resource(:github_repo)
      assert is_nil(result) or is_binary(result)
    end
  end

  describe "identity/0" do
    test "returns a map with name, environment, and resources" do
      identity = Instance.identity()

      assert is_map(identity)
      assert Map.has_key?(identity, :name)
      assert Map.has_key?(identity, :environment)
      assert Map.has_key?(identity, :resources)
      assert is_binary(identity.name)
      assert is_atom(identity.environment)
      assert is_map(identity.resources)
    end
  end

  # ── Sanitization ──────────────────────────────────────────────────

  describe "sanitized_resources/0" do
    test "redacts URL-like values for secret keys" do
      original = Application.get_env(:lattice, :resources)

      Application.put_env(:lattice, :resources,
        github_repo: "plattegruber/lattice",
        fly_org: "lattice-org",
        fly_app: "lattice-app",
        sprites_api_base: "https://api.sprites.example.com/v1"
      )

      sanitized = Instance.sanitized_resources()

      # Non-secret keys are shown in full
      assert sanitized.github_repo == "plattegruber/lattice"
      assert sanitized.fly_org == "lattice-org"
      assert sanitized.fly_app == "lattice-app"

      # Secret keys (containing "api_base") are redacted
      assert sanitized.sprites_api_base == "https://api.sprites.example.com/***"

      Application.put_env(:lattice, :resources, original)
    end

    test "handles nil values without crashing" do
      original = Application.get_env(:lattice, :resources)

      Application.put_env(:lattice, :resources,
        github_repo: nil,
        fly_org: nil,
        fly_app: nil,
        sprites_api_base: nil
      )

      sanitized = Instance.sanitized_resources()
      assert sanitized.github_repo == nil

      Application.put_env(:lattice, :resources, original)
    end
  end

  # ── Validation ────────────────────────────────────────────────────

  describe "validate!/0" do
    test "returns :ok in test environment even with missing bindings" do
      original = Application.get_env(:lattice, :resources)

      Application.put_env(:lattice, :resources,
        github_repo: nil,
        fly_org: nil,
        fly_app: nil,
        sprites_api_base: nil
      )

      assert Instance.validate!() == :ok

      Application.put_env(:lattice, :resources, original)
    end

    test "returns :ok when all bindings are present" do
      original_resources = Application.get_env(:lattice, :resources)

      Application.put_env(:lattice, :resources,
        github_repo: "plattegruber/lattice",
        fly_org: "lattice-org",
        fly_app: "lattice-app",
        sprites_api_base: "https://api.example.com"
      )

      assert Instance.validate!() == :ok

      Application.put_env(:lattice, :resources, original_resources)
    end

    test "raises in prod when bindings are missing" do
      original_instance = Application.get_env(:lattice, :instance)
      original_resources = Application.get_env(:lattice, :resources)

      Application.put_env(:lattice, :instance, name: "prod-test", environment: :prod)

      Application.put_env(:lattice, :resources,
        github_repo: nil,
        fly_org: nil,
        fly_app: nil,
        sprites_api_base: nil
      )

      assert_raise RuntimeError, ~r/Missing required resource bindings for production/, fn ->
        Instance.validate!()
      end

      Application.put_env(:lattice, :instance, original_instance)
      Application.put_env(:lattice, :resources, original_resources)
    end
  end

  # ── Cross-Wiring Guard ───────────────────────────────────────────

  describe "validate_resource!/2" do
    test "returns :ok when the resource matches" do
      original = Application.get_env(:lattice, :resources)

      Application.put_env(:lattice, :resources,
        github_repo: "plattegruber/lattice",
        fly_org: "lattice-org",
        fly_app: "lattice-app",
        sprites_api_base: "https://api.example.com"
      )

      assert Instance.validate_resource!(:github_repo, "plattegruber/lattice") == :ok

      Application.put_env(:lattice, :resources, original)
    end

    test "raises when the resource does not match" do
      original = Application.get_env(:lattice, :resources)

      Application.put_env(:lattice, :resources,
        github_repo: "plattegruber/lattice",
        fly_org: "lattice-org",
        fly_app: "lattice-app",
        sprites_api_base: "https://api.example.com"
      )

      assert_raise ArgumentError, ~r/Resource cross-wiring detected/, fn ->
        Instance.validate_resource!(:github_repo, "other-org/other-repo")
      end

      Application.put_env(:lattice, :resources, original)
    end

    test "returns :ok when the resource is not configured" do
      original = Application.get_env(:lattice, :resources)

      Application.put_env(:lattice, :resources,
        github_repo: nil,
        fly_org: nil,
        fly_app: nil,
        sprites_api_base: nil
      )

      assert Instance.validate_resource!(:github_repo, "any-value") == :ok

      Application.put_env(:lattice, :resources, original)
    end
  end

  # ── Boot Logging ──────────────────────────────────────────────────

  describe "log_boot_info/0" do
    test "returns :ok and does not crash" do
      assert Instance.log_boot_info() == :ok
    end
  end
end
