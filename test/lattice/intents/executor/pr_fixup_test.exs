defmodule Lattice.Intents.Executor.PrFixupTest do
  use ExUnit.Case, async: false

  import Mox

  @moduletag :unit

  alias Lattice.Intents.Executor.PrFixup
  alias Lattice.Intents.Executor.Router
  alias Lattice.Intents.Intent

  setup :verify_on_exit!

  defp pr_fixup_intent(opts \\ []) do
    payload =
      %{
        "pr_url" => Keyword.get(opts, :pr_url, "https://github.com/org/repo/pull/42"),
        "feedback" => Keyword.get(opts, :feedback, "Please fix the typo in README.md"),
        "reviewer" => Keyword.get(opts, :reviewer, "reviewer1"),
        "pr_title" => Keyword.get(opts, :pr_title, "Add feature")
      }
      |> Map.merge(Keyword.get(opts, :extra_payload, %{}))

    %Intent{
      id: Keyword.get(opts, :id, "int_fixup_test"),
      kind: :pr_fixup,
      state: :approved,
      summary: "Address review feedback on PR #42",
      payload: payload,
      source: %{type: :webhook, id: "wh_1"},
      classification: :controlled,
      affected_resources: ["repo:org/repo", "pr:42"],
      expected_side_effects: ["address review on PR #42"],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  describe "can_execute?/1" do
    test "returns true for pr_fixup intent with required fields" do
      intent = pr_fixup_intent()
      assert PrFixup.can_execute?(intent)
    end

    test "returns false for pr_fixup without pr_url" do
      intent = pr_fixup_intent()
      intent = %{intent | payload: Map.delete(intent.payload, "pr_url")}
      refute PrFixup.can_execute?(intent)
    end

    test "returns false for pr_fixup without feedback" do
      intent = pr_fixup_intent()
      intent = %{intent | payload: Map.delete(intent.payload, "feedback")}
      refute PrFixup.can_execute?(intent)
    end

    test "returns false for non-pr_fixup intent" do
      intent = %{pr_fixup_intent() | kind: :action}
      refute PrFixup.can_execute?(intent)
    end
  end

  describe "execute/1" do
    test "executes fixup on sprite with review context" do
      intent =
        pr_fixup_intent(extra_payload: %{"sprite_name" => "atlas"})

      # Mock GitHub review fetching
      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 42 -> {:ok, []} end)
      |> expect(:list_review_comments, fn 42 -> {:ok, []} end)

      # Mock sprite exec
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", script ->
        assert script =~ "gh pr checkout 42"
        assert script =~ "fixup-context.md"
        {:ok, "FIXUP_CONTEXT_WRITTEN\nPR_NUMBER=42\nREPO=org/repo"}
      end)

      assert {:ok, result} = PrFixup.execute(intent)
      assert result.status == :success
      assert Enum.any?(result.artifacts, &(&1.type == "pr_fixup"))
    end

    test "includes review feedback in script" do
      intent =
        pr_fixup_intent(
          feedback: "Fix the naming convention in lib/foo.ex",
          extra_payload: %{"sprite_name" => "atlas"}
        )

      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 42 -> {:ok, []} end)
      |> expect(:list_review_comments, fn 42 -> {:ok, []} end)

      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", script ->
        assert script =~ "Fix the naming convention"
        {:ok, "FIXUP_CONTEXT_WRITTEN"}
      end)

      assert {:ok, result} = PrFixup.execute(intent)
      assert result.status == :success
    end

    test "handles sprite exec failure" do
      intent =
        pr_fixup_intent(extra_payload: %{"sprite_name" => "atlas"})

      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 42 -> {:ok, []} end)
      |> expect(:list_review_comments, fn 42 -> {:ok, []} end)

      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _script -> {:error, :timeout} end)

      assert {:ok, result} = PrFixup.execute(intent)
      assert result.status == :failure
      assert result.error == {:sprite_exec_failed, :timeout}
    end

    test "handles invalid PR URL" do
      intent = pr_fixup_intent(pr_url: "not-a-url")

      assert {:ok, result} = PrFixup.execute(intent)
      assert result.status == :failure
      assert result.error == {:invalid_pr_url, "not-a-url"}
    end

    test "continues when review fetch fails" do
      intent =
        pr_fixup_intent(extra_payload: %{"sprite_name" => "atlas"})

      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 42 -> {:error, :not_found} end)
      |> expect(:list_review_comments, fn 42 -> {:error, :unauthorized} end)

      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _script ->
        {:ok, "FIXUP_CONTEXT_WRITTEN"}
      end)

      assert {:ok, result} = PrFixup.execute(intent)
      assert result.status == :success
    end

    test "extracts commit SHA from output" do
      intent =
        pr_fixup_intent(extra_payload: %{"sprite_name" => "atlas"})

      sha = "abc123def456789012345678901234567890abcd"

      Lattice.Capabilities.MockGitHub
      |> expect(:list_reviews, fn 42 -> {:ok, []} end)
      |> expect(:list_review_comments, fn 42 -> {:ok, []} end)

      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _script ->
        {:ok, "Committed #{sha}\nPushed to remote"}
      end)

      assert {:ok, result} = PrFixup.execute(intent)
      assert Enum.any?(result.artifacts, &(&1.type == "commit" and &1.data == sha))
    end
  end

  describe "router integration" do
    test "router selects PrFixup for pr_fixup intents" do
      intent = pr_fixup_intent()
      assert {:ok, PrFixup} = Router.route(intent)
    end
  end
end
