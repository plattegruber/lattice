defmodule Lattice.Capabilities.GitHub.ProjectPolicyTest do
  use ExUnit.Case, async: false

  import Mox

  @moduletag :unit

  alias Lattice.Capabilities.GitHub.ProjectPolicy

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:lattice, :github_projects, [])
    on_exit(fn -> Application.put_env(:lattice, :github_projects, original) end)
    :ok
  end

  describe "auto_add_governance_issue/1" do
    test "adds issue to project when enabled" do
      Application.put_env(:lattice, :github_projects,
        default_project_id: "PVT_test",
        auto_add_governance_issues: true
      )

      Lattice.Capabilities.MockGitHub
      |> expect(:add_to_project, fn "PVT_test", "I_node_123" ->
        {:ok, %{item_id: "PVTI_new"}}
      end)

      assert :ok = ProjectPolicy.auto_add_governance_issue("I_node_123")
    end

    test "no-ops when disabled" do
      Application.put_env(:lattice, :github_projects,
        default_project_id: "PVT_test",
        auto_add_governance_issues: false
      )

      assert :ok = ProjectPolicy.auto_add_governance_issue("I_node_123")
    end

    test "no-ops when no project configured" do
      Application.put_env(:lattice, :github_projects, [])

      assert :ok = ProjectPolicy.auto_add_governance_issue("I_node_123")
    end

    test "handles failure gracefully" do
      Application.put_env(:lattice, :github_projects,
        default_project_id: "PVT_test",
        auto_add_governance_issues: true
      )

      Lattice.Capabilities.MockGitHub
      |> expect(:add_to_project, fn _, _ -> {:error, :not_found} end)

      assert :ok = ProjectPolicy.auto_add_governance_issue("I_node_123")
    end
  end

  describe "auto_add_output_pr/1" do
    test "adds PR to project when enabled" do
      Application.put_env(:lattice, :github_projects,
        default_project_id: "PVT_test",
        auto_add_output_prs: true
      )

      Lattice.Capabilities.MockGitHub
      |> expect(:add_to_project, fn "PVT_test", "PR_node_456" ->
        {:ok, %{item_id: "PVTI_new"}}
      end)

      assert :ok = ProjectPolicy.auto_add_output_pr("PR_node_456")
    end

    test "no-ops when disabled" do
      Application.put_env(:lattice, :github_projects,
        default_project_id: "PVT_test",
        auto_add_output_prs: false
      )

      assert :ok = ProjectPolicy.auto_add_output_pr("PR_node_456")
    end
  end

  describe "update_status/2" do
    test "updates status when fully configured" do
      Application.put_env(:lattice, :github_projects,
        default_project_id: "PVT_test",
        status_field_id: "PVTF_status",
        status_mapping: %{
          running: "opt_in_progress",
          completed: "opt_done"
        }
      )

      Lattice.Capabilities.MockGitHub
      |> expect(:update_project_item_field, fn "PVT_test", "PVTI_1", "PVTF_status", "opt_done" ->
        {:ok, %{item_id: "PVTI_1"}}
      end)

      assert :ok = ProjectPolicy.update_status("PVTI_1", :completed)
    end

    test "no-ops when state has no mapping" do
      Application.put_env(:lattice, :github_projects,
        default_project_id: "PVT_test",
        status_field_id: "PVTF_status",
        status_mapping: %{completed: "opt_done"}
      )

      # :proposed has no mapping, should be a no-op
      assert :ok = ProjectPolicy.update_status("PVTI_1", :proposed)
    end

    test "no-ops when no project configured" do
      Application.put_env(:lattice, :github_projects, [])

      assert :ok = ProjectPolicy.update_status("PVTI_1", :completed)
    end

    test "handles failure gracefully" do
      Application.put_env(:lattice, :github_projects,
        default_project_id: "PVT_test",
        status_field_id: "PVTF_status",
        status_mapping: %{completed: "opt_done"}
      )

      Lattice.Capabilities.MockGitHub
      |> expect(:update_project_item_field, fn _, _, _, _ -> {:error, :unauthorized} end)

      assert :ok = ProjectPolicy.update_status("PVTI_1", :completed)
    end
  end

  describe "config helpers" do
    test "default_project_id returns nil when not configured" do
      Application.put_env(:lattice, :github_projects, [])
      assert ProjectPolicy.default_project_id() == nil
    end

    test "auto_add_governance_issues? returns false when no project id" do
      Application.put_env(:lattice, :github_projects, auto_add_governance_issues: true)
      refute ProjectPolicy.auto_add_governance_issues?()
    end

    test "auto_add_governance_issues? returns true when configured" do
      Application.put_env(:lattice, :github_projects,
        default_project_id: "PVT_test",
        auto_add_governance_issues: true
      )

      assert ProjectPolicy.auto_add_governance_issues?()
    end
  end
end
