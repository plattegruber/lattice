defmodule Lattice.Intents.GovernanceTest do
  use ExUnit.Case

  import Mox

  @moduletag :unit

  alias Lattice.Intents.Governance
  alias Lattice.Intents.Governance.Labels, as: GovLabels
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS

  @valid_source %{type: :sprite, id: "sprite-001"}
  @cron_source %{type: :cron, id: "daily-health-audit"}

  setup :verify_on_exit!

  setup do
    StoreETS.reset()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp new_action_intent(opts \\ []) do
    source = Keyword.get(opts, :source, @valid_source)
    capability = Keyword.get(opts, :capability, "sprites")
    operation = Keyword.get(opts, :operation, "wake")

    {:ok, intent} =
      Intent.new_action(source,
        summary: Keyword.get(opts, :summary, "Wake sprite for deployment"),
        payload: %{"capability" => capability, "operation" => operation},
        affected_resources: Keyword.get(opts, :affected_resources, ["sprite-001"]),
        expected_side_effects: Keyword.get(opts, :expected_side_effects, ["sprite wakes"]),
        rollback_strategy: Keyword.get(opts, :rollback_strategy, "Sleep the sprite again")
      )

    intent
  end

  defp new_inquiry_intent(opts \\ []) do
    source = Keyword.get(opts, :source, %{type: :operator, id: "op-001"})

    {:ok, intent} =
      Intent.new_inquiry(source,
        summary: Keyword.get(opts, :summary, "Need API key for integration"),
        payload: %{
          "what_requested" => "Production API key",
          "why_needed" => "Integration with external service",
          "scope_of_impact" => "single service",
          "expiration" => "2026-03-01"
        }
      )

    intent
  end

  defp propose_to_awaiting(intent) do
    with_guardrails(
      [allow_controlled: true, require_approval_for_controlled: true],
      fn -> Pipeline.propose(intent) end
    )
  end

  defp with_guardrails(config, fun) do
    previous = Application.get_env(:lattice, :guardrails, [])
    Application.put_env(:lattice, :guardrails, config)

    try do
      fun.()
    after
      Application.put_env(:lattice, :guardrails, previous)
    end
  end

  defp stub_issue_for(issue_number, labels \\ [], comments \\ []) do
    %{
      number: issue_number,
      title: "Governance issue",
      body: "test",
      state: "open",
      labels: labels,
      comments: comments
    }
  end

  # ── create_governance_issue/1 ────────────────────────────────────

  describe "create_governance_issue/1" do
    test "creates a GitHub issue when intent is awaiting_approval" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      Lattice.Capabilities.MockGitHub
      |> expect(:create_issue, fn title, attrs ->
        assert title =~ "[Intent/Action]"
        assert title =~ "Wake sprite for deployment"
        assert GovLabels.awaiting_approval() in attrs.labels
        assert attrs.body =~ "Intent Summary"
        assert attrs.body =~ "Classification"
        assert attrs.body =~ "Affected Resources"
        assert attrs.body =~ "sprite-001"
        assert attrs.body =~ "Expected Side Effects"
        assert attrs.body =~ "Rollback Strategy"
        assert attrs.body =~ awaiting.id

        {:ok, stub_issue_for(42)}
      end)

      assert {:ok, updated} = Governance.create_governance_issue(awaiting)
      assert updated.metadata[:governance_issue] == 42
    end

    test "issue body contains all required structured fields" do
      intent =
        new_action_intent(
          summary: "Deploy to staging",
          affected_resources: ["fly-app-staging"],
          expected_side_effects: ["app restarts"],
          rollback_strategy: "Rollback to previous release"
        )

      {:ok, awaiting} = propose_to_awaiting(intent)

      Lattice.Capabilities.MockGitHub
      |> expect(:create_issue, fn _title, attrs ->
        body = attrs.body

        # Verify all structured sections
        assert body =~ "## Intent Summary"
        assert body =~ "**Kind:** action"
        assert body =~ "Deploy to staging"
        assert body =~ "## Classification"
        assert body =~ "controlled"
        assert body =~ "## Payload"
        assert body =~ "capability"
        assert body =~ "## Affected Resources"
        assert body =~ "fly-app-staging"
        assert body =~ "## Expected Side Effects"
        assert body =~ "app restarts"
        assert body =~ "## Rollback Strategy"
        assert body =~ "Rollback to previous release"
        assert body =~ "## Source"
        assert body =~ "sprite"
        assert body =~ "## Approval"
        assert body =~ GovLabels.approved()
        assert body =~ GovLabels.rejected()
        # Traceability
        assert body =~ "lattice:intent_id="

        {:ok, stub_issue_for(100)}
      end)

      assert {:ok, _} = Governance.create_governance_issue(awaiting)
    end

    test "inquiry intent issues include required inquiry fields" do
      intent = new_inquiry_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      Lattice.Capabilities.MockGitHub
      |> expect(:create_issue, fn title, attrs ->
        assert title =~ "[Intent/Inquiry]"
        body = attrs.body
        assert body =~ "## Inquiry Details"
        assert body =~ "**What is requested:** Production API key"
        assert body =~ "**Why it is needed:** Integration with external service"
        assert body =~ "**Scope of impact:** single service"
        assert body =~ "**Expiration:** 2026-03-01"

        {:ok, stub_issue_for(43)}
      end)

      assert {:ok, _} = Governance.create_governance_issue(awaiting)
    end

    test "returns error when intent is not awaiting_approval" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")
      {:ok, approved} = Pipeline.propose(intent)
      assert approved.state == :approved

      assert {:error, {:wrong_state, :approved}} =
               Governance.create_governance_issue(approved)
    end

    test "returns error when GitHub API fails" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      Lattice.Capabilities.MockGitHub
      |> expect(:create_issue, fn _title, _attrs ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} = Governance.create_governance_issue(awaiting)
    end

    test "stores governance issue number in intent metadata" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      Lattice.Capabilities.MockGitHub
      |> expect(:create_issue, fn _title, _attrs ->
        {:ok, stub_issue_for(99)}
      end)

      {:ok, updated} = Governance.create_governance_issue(awaiting)
      {:ok, fetched} = Store.get(updated.id)
      assert fetched.metadata[:governance_issue] == 99
    end
  end

  # ── sync_from_github/1 ──────────────────────────────────────────

  describe "sync_from_github/1" do
    test "approves intent when intent-approved label is present" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      # Add governance issue to metadata
      metadata = Map.put(awaiting.metadata, :governance_issue, 42)
      {:ok, with_issue} = Store.update(awaiting.id, %{metadata: metadata})

      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 ->
        {:ok, stub_issue_for(42, [GovLabels.approved()])}
      end)

      assert {:ok, %Intent{state: :approved}} = Governance.sync_from_github(with_issue)

      {:ok, fetched} = Store.get(with_issue.id)
      assert fetched.state == :approved
    end

    test "rejects intent when intent-rejected label is present" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      metadata = Map.put(awaiting.metadata, :governance_issue, 42)
      {:ok, with_issue} = Store.update(awaiting.id, %{metadata: metadata})

      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 ->
        {:ok, stub_issue_for(42, [GovLabels.rejected()])}
      end)

      assert {:ok, %Intent{state: :rejected}} = Governance.sync_from_github(with_issue)

      {:ok, fetched} = Store.get(with_issue.id)
      assert fetched.state == :rejected
    end

    test "returns :no_change when no actionable label is found" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      metadata = Map.put(awaiting.metadata, :governance_issue, 42)
      {:ok, with_issue} = Store.update(awaiting.id, %{metadata: metadata})

      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 ->
        {:ok, stub_issue_for(42, [GovLabels.awaiting_approval()])}
      end)

      assert {:ok, :no_change} = Governance.sync_from_github(with_issue)
    end

    test "returns error when no governance issue is linked" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      assert {:error, :no_governance_issue} = Governance.sync_from_github(awaiting)
    end

    test "captures GitHub comments as metadata on approval" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      metadata = Map.put(awaiting.metadata, :governance_issue, 42)
      {:ok, with_issue} = Store.update(awaiting.id, %{metadata: metadata})

      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 ->
        {:ok,
         stub_issue_for(42, [GovLabels.approved()], [
           %{id: 1, body: "Looks good to me"},
           %{id: 2, body: "Approved for deployment"}
         ])}
      end)

      assert {:ok, %Intent{}} = Governance.sync_from_github(with_issue)

      {:ok, fetched} = Store.get(with_issue.id)
      assert is_list(fetched.metadata[:github_comments])
      assert length(fetched.metadata[:github_comments]) == 2
    end

    test "returns error when intent is not awaiting_approval" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")
      {:ok, approved} = Pipeline.propose(intent)

      assert {:error, {:wrong_state, :approved}} = Governance.sync_from_github(approved)
    end
  end

  # ── post_outcome/2 ──────────────────────────────────────────────

  describe "post_outcome/2" do
    test "posts execution outcome as a comment on the governance issue" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      metadata = Map.put(awaiting.metadata, :governance_issue, 42)
      {:ok, with_issue} = Store.update(awaiting.id, %{metadata: metadata})

      result = %{status: :success, output: "deployed", duration_ms: 1500}

      Lattice.Capabilities.MockGitHub
      |> expect(:create_comment, fn 42, body ->
        assert body =~ "Execution Outcome"
        assert body =~ "Completed"
        assert body =~ "1500ms"
        assert body =~ "deployed"

        {:ok, %{id: 1, body: body, issue_number: 42}}
      end)

      assert {:ok, _comment} = Governance.post_outcome(with_issue, result)
    end

    test "posts failure outcome with error details" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      metadata = Map.put(awaiting.metadata, :governance_issue, 42)
      {:ok, with_issue} = Store.update(awaiting.id, %{metadata: metadata})

      result = %{status: :failure, error: :timeout, duration_ms: 30_000}

      Lattice.Capabilities.MockGitHub
      |> expect(:create_comment, fn 42, body ->
        assert body =~ "Failed"
        assert body =~ "timeout"

        {:ok, %{id: 2, body: body, issue_number: 42}}
      end)

      assert {:ok, _comment} = Governance.post_outcome(with_issue, result)
    end

    test "returns error when no governance issue is linked" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      assert {:error, :no_governance_issue} =
               Governance.post_outcome(awaiting, %{status: :success})
    end
  end

  # ── close_governance_issue/1 ────────────────────────────────────

  describe "close_governance_issue/1" do
    test "closes the issue when intent is completed" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      metadata = Map.put(awaiting.metadata, :governance_issue, 42)
      {:ok, with_issue} = Store.update(awaiting.id, %{metadata: metadata})

      # Manually transition to approved -> running -> completed for test
      {:ok, approved} =
        Store.update(with_issue.id, %{state: :approved, actor: :test, reason: "test"})

      {:ok, running} =
        Store.update(approved.id, %{state: :running, actor: :test, reason: "test"})

      {:ok, completed} =
        Store.update(running.id, %{state: :completed, actor: :test, reason: "test"})

      Lattice.Capabilities.MockGitHub
      |> expect(:update_issue, fn 42, %{state: "closed"} ->
        {:ok, stub_issue_for(42)}
      end)

      assert {:ok, _issue} = Governance.close_governance_issue(completed)
    end

    test "closes and labels the issue when intent is rejected" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      metadata = Map.put(awaiting.metadata, :governance_issue, 42)
      {:ok, with_issue} = Store.update(awaiting.id, %{metadata: metadata})

      {:ok, rejected} =
        Store.update(with_issue.id, %{state: :rejected, actor: :test, reason: "test"})

      Lattice.Capabilities.MockGitHub
      |> expect(:add_label, fn 42, label ->
        assert label == GovLabels.rejected()
        {:ok, [label]}
      end)
      |> expect(:update_issue, fn 42, %{state: "closed"} ->
        {:ok, stub_issue_for(42)}
      end)

      assert {:ok, _issue} = Governance.close_governance_issue(rejected)
    end

    test "returns error when intent is not in terminal state" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      assert {:error, {:not_terminal, :awaiting_approval}} =
               Governance.close_governance_issue(awaiting)
    end

    test "returns error when no governance issue is linked" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      {:ok, rejected} =
        Store.update(awaiting.id, %{state: :rejected, actor: :test, reason: "test"})

      assert {:error, :no_governance_issue} = Governance.close_governance_issue(rejected)
    end
  end

  # ── Cron-proposed intents ───────────────────────────────────────

  describe "cron-proposed intents" do
    test "cron intents flow through full pipeline and create governance issues" do
      intent = new_action_intent(source: @cron_source, summary: "Daily health audit")
      {:ok, awaiting} = propose_to_awaiting(intent)

      assert awaiting.state == :awaiting_approval
      assert awaiting.source.type == :cron
      assert awaiting.source.id == "daily-health-audit"

      Lattice.Capabilities.MockGitHub
      |> expect(:create_issue, fn title, attrs ->
        assert title =~ "[Intent/Action]"
        assert title =~ "Daily health audit"
        assert attrs.body =~ "cron"
        assert attrs.body =~ "daily-health-audit"

        {:ok, stub_issue_for(50)}
      end)

      assert {:ok, updated} = Governance.create_governance_issue(awaiting)
      assert updated.metadata[:governance_issue] == 50
    end
  end

  # ── Immutability ────────────────────────────────────────────────

  describe "immutability" do
    test "GitHub interactions cannot mutate approved intent payload" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      metadata = Map.put(awaiting.metadata, :governance_issue, 42)
      {:ok, with_issue} = Store.update(awaiting.id, %{metadata: metadata})

      # Approve the intent
      Lattice.Capabilities.MockGitHub
      |> expect(:get_issue, fn 42 ->
        {:ok, stub_issue_for(42, [GovLabels.approved()])}
      end)

      {:ok, %Intent{state: :approved}} = Governance.sync_from_github(with_issue)

      # Verify payload is frozen
      {:ok, approved} = Store.get(with_issue.id)
      assert approved.state == :approved

      # Attempt to mutate frozen fields should fail
      assert {:error, :immutable} =
               Store.update(approved.id, %{payload: %{"changed" => true}})

      assert {:error, :immutable} =
               Store.update(approved.id, %{affected_resources: ["new-resource"]})
    end
  end

  # ── format_issue_body/1 ─────────────────────────────────────────

  describe "format_issue_body/1" do
    test "formats action intent body with all sections" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      body = Governance.format_issue_body(awaiting)

      assert body =~ "## Intent Summary"
      assert body =~ "**Kind:** action"
      assert body =~ "Wake sprite for deployment"
      assert body =~ "## Classification"
      assert body =~ "controlled"
      assert body =~ "## Payload"
      assert body =~ "## Affected Resources"
      assert body =~ "sprite-001"
      assert body =~ "## Expected Side Effects"
      assert body =~ "sprite wakes"
      assert body =~ "## Rollback Strategy"
      assert body =~ "Sleep the sprite again"
      assert body =~ "## Source"
      assert body =~ "sprite"
      assert body =~ "sprite-001"
      assert body =~ "## Approval"
      assert body =~ GovLabels.approved()
      assert body =~ GovLabels.rejected()
    end

    test "formats inquiry intent body with inquiry details" do
      intent = new_inquiry_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      body = Governance.format_issue_body(awaiting)

      assert body =~ "## Inquiry Details"
      assert body =~ "**What is requested:** Production API key"
      assert body =~ "**Why it is needed:** Integration with external service"
      assert body =~ "**Scope of impact:** single service"
      assert body =~ "**Expiration:** 2026-03-01"
    end

    test "includes traceability footer with intent ID" do
      intent = new_action_intent()
      {:ok, awaiting} = propose_to_awaiting(intent)

      body = Governance.format_issue_body(awaiting)

      assert body =~ "lattice:intent_id=#{awaiting.id}"
    end
  end
end
