defmodule Lattice.PRs.PRTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Lattice.PRs.PR

  describe "new/3" do
    test "creates a PR with required fields and defaults" do
      pr = PR.new(42, "org/repo")

      assert pr.number == 42
      assert pr.repo == "org/repo"
      assert pr.state == :open
      assert pr.review_state == :pending
      assert pr.draft == false
      assert pr.mergeable == nil
      assert pr.ci_status == nil
      assert %DateTime{} = pr.created_at
      assert %DateTime{} = pr.updated_at
    end

    test "creates a PR with optional fields" do
      pr =
        PR.new(10, "org/repo",
          title: "Add feature",
          head_branch: "feat/add-feature",
          base_branch: "main",
          state: :open,
          review_state: :approved,
          draft: true,
          intent_id: "int_abc",
          run_id: "run_123",
          url: "https://github.com/org/repo/pull/10"
        )

      assert pr.title == "Add feature"
      assert pr.head_branch == "feat/add-feature"
      assert pr.base_branch == "main"
      assert pr.review_state == :approved
      assert pr.draft == true
      assert pr.intent_id == "int_abc"
      assert pr.run_id == "run_123"
      assert pr.url == "https://github.com/org/repo/pull/10"
    end
  end

  describe "update/2" do
    test "updates fields and bumps updated_at" do
      pr = PR.new(1, "org/repo")
      original_updated_at = pr.updated_at

      # Small delay to ensure timestamp differs
      Process.sleep(1)
      updated = PR.update(pr, review_state: :approved, mergeable: true)

      assert updated.review_state == :approved
      assert updated.mergeable == true
      assert DateTime.compare(updated.updated_at, original_updated_at) in [:gt, :eq]
    end
  end

  describe "needs_attention?/1" do
    test "returns true for changes_requested" do
      pr = PR.new(1, "org/repo") |> struct!(review_state: :changes_requested)
      assert PR.needs_attention?(pr)
    end

    test "returns true for failing CI" do
      pr = PR.new(1, "org/repo") |> struct!(ci_status: :failure)
      assert PR.needs_attention?(pr)
    end

    test "returns true for non-mergeable" do
      pr = PR.new(1, "org/repo") |> struct!(mergeable: false)
      assert PR.needs_attention?(pr)
    end

    test "returns false for approved PR" do
      pr = PR.new(1, "org/repo") |> struct!(review_state: :approved)
      refute PR.needs_attention?(pr)
    end

    test "returns false for merged PR" do
      pr = PR.new(1, "org/repo") |> struct!(state: :merged, review_state: :changes_requested)
      refute PR.needs_attention?(pr)
    end
  end

  describe "merge_ready?/1" do
    test "returns true when approved, mergeable, CI passing" do
      pr =
        PR.new(1, "org/repo")
        |> struct!(review_state: :approved, mergeable: true, ci_status: :success)

      assert PR.merge_ready?(pr)
    end

    test "returns true when approved, mergeable, no CI info" do
      pr =
        PR.new(1, "org/repo")
        |> struct!(review_state: :approved, mergeable: true, ci_status: nil)

      assert PR.merge_ready?(pr)
    end

    test "returns false when not approved" do
      pr =
        PR.new(1, "org/repo")
        |> struct!(review_state: :pending, mergeable: true, ci_status: :success)

      refute PR.merge_ready?(pr)
    end

    test "returns false when not mergeable" do
      pr =
        PR.new(1, "org/repo")
        |> struct!(review_state: :approved, mergeable: false, ci_status: :success)

      refute PR.merge_ready?(pr)
    end

    test "returns false when CI failing" do
      pr =
        PR.new(1, "org/repo")
        |> struct!(review_state: :approved, mergeable: true, ci_status: :failure)

      refute PR.merge_ready?(pr)
    end

    test "returns false for closed PR" do
      pr =
        PR.new(1, "org/repo")
        |> struct!(
          state: :closed,
          review_state: :approved,
          mergeable: true,
          ci_status: :success
        )

      refute PR.merge_ready?(pr)
    end
  end
end
