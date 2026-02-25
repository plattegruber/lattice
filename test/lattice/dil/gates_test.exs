defmodule Lattice.DIL.GatesTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  import Mox

  alias Lattice.DIL.Gates

  setup :verify_on_exit!

  # Helper to temporarily set DIL config for a test
  defp with_dil_config(config, fun) do
    previous = Application.get_env(:lattice, :dil, [])
    Application.put_env(:lattice, :dil, config)

    try do
      fun.()
    after
      Application.put_env(:lattice, :dil, previous)
    end
  end

  # ── enabled? ─────────────────────────────────────────────────────────

  describe "enabled?/0" do
    test "returns false when dil config is missing" do
      with_dil_config([], fn ->
        refute Gates.enabled?()
      end)
    end

    test "returns false when enabled is false" do
      with_dil_config([enabled: false], fn ->
        refute Gates.enabled?()
      end)
    end

    test "returns true when enabled is true" do
      with_dil_config([enabled: true], fn ->
        assert Gates.enabled?()
      end)
    end
  end

  # ── open_dil_issue? ──────────────────────────────────────────────────

  describe "open_dil_issue?/0" do
    test "returns true when open dil-proposal issues exist" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn opts ->
        assert opts[:labels] == "dil-proposal"
        assert opts[:state] == "open"
        {:ok, [%{"number" => 42, "title" => "[DIL] Some improvement"}]}
      end)

      assert Gates.open_dil_issue?()
    end

    test "returns false when no open dil-proposal issues" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:ok, []} end)

      refute Gates.open_dil_issue?()
    end

    test "returns false on GitHub error" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:error, :api_error} end)

      refute Gates.open_dil_issue?()
    end
  end

  # ── cooldown_elapsed? ────────────────────────────────────────────────

  describe "cooldown_elapsed?/0" do
    test "returns true when most recent issue is older than cooldown" do
      old_time = DateTime.add(DateTime.utc_now(), -25, :hour) |> DateTime.to_iso8601()

      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn opts ->
        assert opts[:labels] == "dil-proposal"
        assert opts[:state] == "all"
        {:ok, [%{"created_at" => old_time}]}
      end)

      with_dil_config([enabled: true, cooldown_hours: 24], fn ->
        assert Gates.cooldown_elapsed?()
      end)
    end

    test "returns false when most recent issue is within cooldown" do
      recent_time = DateTime.add(DateTime.utc_now(), -2, :hour) |> DateTime.to_iso8601()

      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts ->
        {:ok, [%{"created_at" => recent_time}]}
      end)

      with_dil_config([enabled: true, cooldown_hours: 24], fn ->
        refute Gates.cooldown_elapsed?()
      end)
    end

    test "returns true when no previous DIL issues exist" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:ok, []} end)

      assert Gates.cooldown_elapsed?()
    end

    test "returns false on GitHub error (fail closed)" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:error, :api_error} end)

      refute Gates.cooldown_elapsed?()
    end
  end

  # ── recent_rejection? ────────────────────────────────────────────────

  describe "recent_rejection?/0" do
    test "returns true when a closed issue is within rejection cooldown" do
      recent_close = DateTime.add(DateTime.utc_now(), -12, :hour) |> DateTime.to_iso8601()

      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn opts ->
        assert opts[:labels] == "dil-proposal"
        assert opts[:state] == "closed"
        {:ok, [%{"closed_at" => recent_close}]}
      end)

      with_dil_config([enabled: true, rejection_cooldown_hours: 48], fn ->
        assert Gates.recent_rejection?()
      end)
    end

    test "returns false when closed issues are older than rejection cooldown" do
      old_close = DateTime.add(DateTime.utc_now(), -72, :hour) |> DateTime.to_iso8601()

      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts ->
        {:ok, [%{"closed_at" => old_close}]}
      end)

      with_dil_config([enabled: true, rejection_cooldown_hours: 48], fn ->
        refute Gates.recent_rejection?()
      end)
    end

    test "returns false when no closed dil-proposal issues" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:ok, []} end)

      with_dil_config([enabled: true, rejection_cooldown_hours: 48], fn ->
        refute Gates.recent_rejection?()
      end)
    end

    test "returns true on GitHub error (fail closed)" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts -> {:error, :api_error} end)

      assert Gates.recent_rejection?()
    end
  end

  # ── check_all ────────────────────────────────────────────────────────

  describe "check_all/0" do
    test "skips when disabled" do
      with_dil_config([enabled: false], fn ->
        assert {:skip, "DIL is disabled"} = Gates.check_all()
      end)
    end

    test "skips when open DIL issue exists" do
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn _opts ->
        {:ok, [%{"number" => 1, "title" => "[DIL] Open proposal"}]}
      end)

      with_dil_config([enabled: true, cooldown_hours: 24, rejection_cooldown_hours: 48], fn ->
        assert {:skip, "open DIL issue exists"} = Gates.check_all()
      end)
    end

    test "returns gates_passed when all gates pass" do
      # Gate: no open issues
      Lattice.Capabilities.MockGitHub
      |> expect(:list_issues, fn opts ->
        assert opts[:state] == "open"
        {:ok, []}
      end)
      # Gate: cooldown elapsed
      |> expect(:list_issues, fn opts ->
        assert opts[:state] == "all"
        old_time = DateTime.add(DateTime.utc_now(), -48, :hour) |> DateTime.to_iso8601()
        {:ok, [%{"created_at" => old_time}]}
      end)
      # Gate: no recent rejection
      |> expect(:list_issues, fn opts ->
        assert opts[:state] == "closed"
        {:ok, []}
      end)

      with_dil_config([enabled: true, cooldown_hours: 24, rejection_cooldown_hours: 48], fn ->
        assert {:ok, :gates_passed} = Gates.check_all()
      end)
    end
  end
end
