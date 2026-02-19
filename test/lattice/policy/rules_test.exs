defmodule Lattice.Policy.RulesTest do
  use ExUnit.Case, async: false

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Policy.RepoProfile
  alias Lattice.Policy.Rules

  defp make_intent(opts \\ []) do
    source = %{type: :system, id: "test"}

    {:ok, intent} =
      Intent.new(:health_detect, source,
        summary: Keyword.get(opts, :summary, "test"),
        payload:
          Keyword.get(opts, :payload, %{
            "observation_type" => "anomaly",
            "severity" => "high",
            "sprite_id" => "test-sprite"
          })
      )

    intent
    |> Map.put(:affected_resources, Keyword.get(opts, :affected_resources, []))
    |> Map.put(:classification, Keyword.get(opts, :classification, :controlled))
  end

  describe "evaluate/1" do
    test "returns :no_match when no rules configured" do
      Application.put_env(:lattice, Rules, rules: [])

      intent = make_intent()
      assert Rules.evaluate(intent) == :no_match
    after
      Application.delete_env(:lattice, Rules)
    end

    test "path_auto_approve allows when all files match" do
      Application.put_env(:lattice, Rules,
        rules: [%{type: :path_auto_approve, paths: ["README.md", "docs/"]}]
      )

      intent = make_intent(affected_resources: ["file:README.md", "file:docs/guide.md"])
      assert Rules.evaluate(intent) == :allow
    after
      Application.delete_env(:lattice, Rules)
    end

    test "path_auto_approve returns :no_match when files outside allowed paths" do
      Application.put_env(:lattice, Rules, rules: [%{type: :path_auto_approve, paths: ["docs/"]}])

      intent = make_intent(affected_resources: ["file:docs/guide.md", "file:lib/core.ex"])
      assert Rules.evaluate(intent) == :no_match
    after
      Application.delete_env(:lattice, Rules)
    end

    test "path_auto_approve returns :no_match when no file resources" do
      Application.put_env(:lattice, Rules, rules: [%{type: :path_auto_approve, paths: ["docs/"]}])

      intent = make_intent(affected_resources: ["sprite:test"])
      assert Rules.evaluate(intent) == :no_match
    after
      Application.delete_env(:lattice, Rules)
    end

    test "time_gate denies outside hours for controlled intents" do
      # Set gate to only allow during a 1-hour window that's definitely not now
      # (use hour 25 which will never match)
      Application.put_env(:lattice, Rules, rules: [%{type: :time_gate, deny_outside: {25, 26}}])

      intent = make_intent(classification: :controlled)
      assert Rules.evaluate(intent) == :deny
    after
      Application.delete_env(:lattice, Rules)
    end

    test "time_gate returns :no_match for safe intents" do
      Application.put_env(:lattice, Rules, rules: [%{type: :time_gate, deny_outside: {25, 26}}])

      intent = make_intent(classification: :safe)
      assert Rules.evaluate(intent) == :no_match
    after
      Application.delete_env(:lattice, Rules)
    end

    test "repo_override allows for matching repo" do
      Application.put_env(:lattice, Rules,
        rules: [%{type: :repo_override, repo: "org/my-repo", allow: true}]
      )

      intent =
        make_intent(
          payload: %{
            "repo" => "org/my-repo",
            "observation_type" => "anomaly",
            "severity" => "high",
            "sprite_id" => "test"
          }
        )

      assert Rules.evaluate(intent) == :allow
    after
      Application.delete_env(:lattice, Rules)
    end

    test "repo_override denies for matching repo" do
      Application.put_env(:lattice, Rules,
        rules: [%{type: :repo_override, repo: "org/blocked-repo", deny: true}]
      )

      intent =
        make_intent(
          payload: %{
            "repo" => "org/blocked-repo",
            "observation_type" => "anomaly",
            "severity" => "high",
            "sprite_id" => "test"
          }
        )

      assert Rules.evaluate(intent) == :deny
    after
      Application.delete_env(:lattice, Rules)
    end

    test "repo_override returns :no_match for non-matching repo" do
      Application.put_env(:lattice, Rules,
        rules: [%{type: :repo_override, repo: "org/other", allow: true}]
      )

      intent =
        make_intent(
          payload: %{
            "repo" => "org/different",
            "observation_type" => "anomaly",
            "severity" => "high",
            "sprite_id" => "test"
          }
        )

      assert Rules.evaluate(intent) == :no_match
    after
      Application.delete_env(:lattice, Rules)
    end

    test "first matching rule wins" do
      Application.put_env(:lattice, Rules,
        rules: [
          %{type: :repo_override, repo: "org/repo", deny: true},
          %{type: :repo_override, repo: "org/repo", allow: true}
        ]
      )

      intent =
        make_intent(
          payload: %{
            "repo" => "org/repo",
            "observation_type" => "anomaly",
            "severity" => "high",
            "sprite_id" => "test"
          }
        )

      assert Rules.evaluate(intent) == :deny
    after
      Application.delete_env(:lattice, Rules)
    end
  end

  describe "path_auto_approved?/2" do
    test "checks against repo profile auto_approve_paths" do
      RepoProfile.put(%RepoProfile{
        repo: "test/path-check",
        auto_approve_paths: ["README.md", "docs/"]
      })

      assert Rules.path_auto_approved?("test/path-check", "README.md")
      assert Rules.path_auto_approved?("test/path-check", "docs/guide.md")
      refute Rules.path_auto_approved?("test/path-check", "lib/core.ex")
    after
      RepoProfile.delete("test/path-check")
    end
  end

  describe "path_in_risk_zone?/2" do
    test "checks against repo profile risk_zones" do
      RepoProfile.put(%RepoProfile{
        repo: "test/risk-check",
        risk_zones: ["lib/safety/", "config/"]
      })

      assert Rules.path_in_risk_zone?("test/risk-check", "lib/safety/gate.ex")
      assert Rules.path_in_risk_zone?("test/risk-check", "config/prod.exs")
      refute Rules.path_in_risk_zone?("test/risk-check", "lib/sprites/sprite.ex")
    after
      RepoProfile.delete("test/risk-check")
    end
  end

  describe "list_rules/0" do
    test "returns configured rules" do
      Application.put_env(:lattice, Rules, rules: [%{type: :path_auto_approve, paths: ["docs/"]}])

      rules = Rules.list_rules()
      assert length(rules) == 1
      assert hd(rules).type == :path_auto_approve
    after
      Application.delete_env(:lattice, Rules)
    end

    test "returns empty list when no rules configured" do
      Application.delete_env(:lattice, Rules)
      assert Rules.list_rules() == []
    end
  end
end
