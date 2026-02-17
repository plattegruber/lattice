defmodule Lattice.Intents.PipelineTest do
  use ExUnit.Case

  @moduletag :unit

  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS

  @valid_source %{type: :sprite, id: "sprite-001"}

  setup do
    StoreETS.reset()
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp new_action_intent(opts \\ []) do
    source = Keyword.get(opts, :source, @valid_source)
    capability = Keyword.get(opts, :capability, "sprites")
    operation = Keyword.get(opts, :operation, "list_sprites")

    {:ok, intent} =
      Intent.new_action(source,
        summary: Keyword.get(opts, :summary, "List all sprites"),
        payload: %{"capability" => capability, "operation" => operation},
        affected_resources: Keyword.get(opts, :affected_resources, ["sprites"]),
        expected_side_effects: Keyword.get(opts, :expected_side_effects, ["none"])
      )

    intent
  end

  defp new_inquiry_intent(opts \\ []) do
    source = Keyword.get(opts, :source, %{type: :operator, id: "op-001"})

    {:ok, intent} =
      Intent.new_inquiry(source,
        summary: Keyword.get(opts, :summary, "Need API key"),
        payload: %{
          "what_requested" => "API key",
          "why_needed" => "Integration",
          "scope_of_impact" => "single service",
          "expiration" => "2026-03-01"
        }
      )

    intent
  end

  defp new_maintenance_intent(opts \\ []) do
    source = Keyword.get(opts, :source, @valid_source)

    {:ok, intent} =
      Intent.new_maintenance(source,
        summary: Keyword.get(opts, :summary, "Update base image"),
        payload: %{"image" => "elixir:1.18"}
      )

    intent
  end

  defp new_task_intent(opts \\ []) do
    source = Keyword.get(opts, :source, @valid_source)
    sprite_name = Keyword.get(opts, :sprite_name, "my-sprite")
    repo = Keyword.get(opts, :repo, "owner/repo")

    {:ok, intent} =
      Intent.new_task(source, sprite_name, repo,
        task_kind: Keyword.get(opts, :task_kind, "open_pr_trivial_change"),
        instructions: Keyword.get(opts, :instructions, "Add timestamp to README"),
        pr_title: Keyword.get(opts, :pr_title),
        pr_body: Keyword.get(opts, :pr_body)
      )

    intent
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

  defp with_task_allowlist(repos, fun) do
    previous = Application.get_env(:lattice, :task_allowlist, [])
    Application.put_env(:lattice, :task_allowlist, auto_approve_repos: repos)

    try do
      fun.()
    after
      Application.put_env(:lattice, :task_allowlist, previous)
    end
  end

  # ── propose/1 ──────────────────────────────────────────────────────

  describe "propose/1" do
    test "SAFE action intent auto-advances from proposed to approved" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")

      assert {:ok, result} = Pipeline.propose(intent)
      assert result.state == :approved
      assert result.classification == :safe
      assert result.id == intent.id
    end

    test "CONTROLLED action intent stops at awaiting_approval" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")

          assert {:ok, result} = Pipeline.propose(intent)
          assert result.state == :awaiting_approval
          assert result.classification == :controlled
        end
      )
    end

    test "DANGEROUS action intent stops at awaiting_approval" do
      with_guardrails(
        [allow_dangerous: true],
        fn ->
          intent = new_action_intent(capability: "fly", operation: "deploy")

          assert {:ok, result} = Pipeline.propose(intent)
          assert result.state == :awaiting_approval
          assert result.classification == :dangerous
        end
      )
    end

    test "inquiry intent classified as controlled, stops at awaiting_approval" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_inquiry_intent()

          assert {:ok, result} = Pipeline.propose(intent)
          assert result.state == :awaiting_approval
          assert result.classification == :controlled
        end
      )
    end

    test "maintenance intent classified as safe, auto-advances to approved" do
      intent = new_maintenance_intent()

      assert {:ok, result} = Pipeline.propose(intent)
      assert result.state == :approved
      assert result.classification == :safe
    end

    test "unknown capability/operation defaults to controlled" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "unknown", operation: "unknown")

          assert {:ok, result} = Pipeline.propose(intent)
          assert result.classification == :controlled
          assert result.state == :awaiting_approval
        end
      )
    end

    test "CONTROLLED intent auto-advances to approved when approval not required" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: false],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")

          assert {:ok, result} = Pipeline.propose(intent)
          assert result.state == :approved
          assert result.classification == :controlled
        end
      )
    end

    test "persists intent in store" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")

      {:ok, result} = Pipeline.propose(intent)
      {:ok, fetched} = Store.get(result.id)

      assert fetched.id == result.id
      assert fetched.state == :approved
    end

    test "builds transition log through pipeline" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")

      {:ok, result} = Pipeline.propose(intent)
      {:ok, history} = Store.get_history(result.id)

      assert length(history) == 2
      states = Enum.map(history, & &1.to)
      assert states == [:classified, :approved]
    end

    test "sets classified_at timestamp" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")

      {:ok, result} = Pipeline.propose(intent)
      assert %DateTime{} = result.classified_at
    end

    test "sets approved_at timestamp for auto-approved intents" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")

      {:ok, result} = Pipeline.propose(intent)
      assert %DateTime{} = result.approved_at
    end
  end

  # ── approve/2 ──────────────────────────────────────────────────────

  describe "approve/2" do
    test "transitions from awaiting_approval to approved with actor" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)
          assert awaiting.state == :awaiting_approval

          assert {:ok, approved} = Pipeline.approve(awaiting.id, actor: "human-reviewer")
          assert approved.state == :approved
          assert %DateTime{} = approved.approved_at

          {:ok, history} = Store.get_history(approved.id)
          last_entry = List.last(history)
          assert last_entry.actor == "human-reviewer"
          assert last_entry.to == :approved
        end
      )
    end

    test "fails when intent is not awaiting_approval" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")
      {:ok, approved} = Pipeline.propose(intent)
      assert approved.state == :approved

      assert {:error, {:invalid_transition, _}} = Pipeline.approve(approved.id, actor: "human")
    end

    test "tracks reason in transition log" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)

          {:ok, approved} =
            Pipeline.approve(awaiting.id, actor: "admin", reason: "reviewed and approved")

          {:ok, history} = Store.get_history(approved.id)
          last_entry = List.last(history)
          assert last_entry.reason == "reviewed and approved"
        end
      )
    end
  end

  # ── reject/2 ───────────────────────────────────────────────────────

  describe "reject/2" do
    test "transitions from awaiting_approval to rejected" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)

          assert {:ok, rejected} =
                   Pipeline.reject(awaiting.id, actor: "reviewer", reason: "too risky")

          assert rejected.state == :rejected

          {:ok, history} = Store.get_history(rejected.id)
          last_entry = List.last(history)
          assert last_entry.actor == "reviewer"
          assert last_entry.reason == "too risky"
        end
      )
    end

    test "fails when intent is not awaiting_approval" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")
      {:ok, approved} = Pipeline.propose(intent)

      assert {:error, {:invalid_transition, _}} = Pipeline.reject(approved.id, actor: "human")
    end
  end

  # ── cancel/2 ───────────────────────────────────────────────────────

  describe "cancel/2" do
    test "cancels from awaiting_approval" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)

          assert {:ok, canceled} =
                   Pipeline.cancel(awaiting.id, actor: "operator", reason: "no longer needed")

          assert canceled.state == :canceled

          {:ok, history} = Store.get_history(canceled.id)
          last_entry = List.last(history)
          assert last_entry.actor == "operator"
          assert last_entry.reason == "no longer needed"
        end
      )
    end

    test "cancels from approved" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")
      {:ok, approved} = Pipeline.propose(intent)
      assert approved.state == :approved

      assert {:ok, canceled} = Pipeline.cancel(approved.id, actor: "operator")
      assert canceled.state == :canceled
    end

    test "fails from terminal state" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)
          {:ok, rejected} = Pipeline.reject(awaiting.id, actor: "reviewer")
          assert rejected.state == :rejected

          assert {:error, {:invalid_transition, _}} =
                   Pipeline.cancel(rejected.id, actor: "operator")
        end
      )
    end
  end

  # ── Task intent gating ────────────────────────────────────────────

  describe "task intent gating" do
    test "task intent classified as controlled stops at awaiting_approval by default" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_task_intent(repo: "owner/non-allowlisted")

          assert {:ok, result} = Pipeline.propose(intent)
          assert result.state == :awaiting_approval
          assert result.classification == :controlled
        end
      )
    end

    test "task intent targeting allowlisted repo auto-approves" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          with_task_allowlist(["owner/allowlisted-repo"], fn ->
            intent = new_task_intent(repo: "owner/allowlisted-repo")

            assert {:ok, result} = Pipeline.propose(intent)
            assert result.state == :approved
            assert result.classification == :controlled
          end)
        end
      )
    end

    test "task intent targeting non-allowlisted repo requires approval" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          with_task_allowlist(["owner/other-repo"], fn ->
            intent = new_task_intent(repo: "owner/not-in-list")

            assert {:ok, result} = Pipeline.propose(intent)
            assert result.state == :awaiting_approval
            assert result.classification == :controlled
          end)
        end
      )
    end

    test "non-task controlled intent is not affected by task allowlist" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          with_task_allowlist(["owner/repo"], fn ->
            # This is a regular controlled action, not a task
            intent = new_action_intent(capability: "sprites", operation: "wake")

            assert {:ok, result} = Pipeline.propose(intent)
            assert result.state == :awaiting_approval
            assert result.classification == :controlled
          end)
        end
      )
    end

    test "allowlisted task intent transition log shows allowlisted repo reason" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          with_task_allowlist(["owner/repo"], fn ->
            intent = new_task_intent(repo: "owner/repo")

            {:ok, result} = Pipeline.propose(intent)
            {:ok, history} = Store.get_history(result.id)

            approval_entry = Enum.find(history, &(&1.to == :approved))
            assert approval_entry.reason == "auto-approved (allowlisted repo)"
          end)
        end
      )
    end
  end

  # ── classify_intent/1 ──────────────────────────────────────────────

  describe "classify_intent/1" do
    test "classifies action intents using Safety.Classifier" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")
      assert {:ok, :safe} = Pipeline.classify_intent(intent)
    end

    test "classifies controlled action intents" do
      intent = new_action_intent(capability: "sprites", operation: "wake")
      assert {:ok, :controlled} = Pipeline.classify_intent(intent)
    end

    test "classifies dangerous action intents" do
      intent = new_action_intent(capability: "fly", operation: "deploy")
      assert {:ok, :dangerous} = Pipeline.classify_intent(intent)
    end

    test "classifies task intents as controlled" do
      intent = new_task_intent()
      assert {:ok, :controlled} = Pipeline.classify_intent(intent)
    end

    test "defaults unknown action intents to controlled" do
      intent = new_action_intent(capability: "nonexistent", operation: "op")
      assert {:ok, :controlled} = Pipeline.classify_intent(intent)
    end

    test "classifies inquiry intents as controlled" do
      intent = new_inquiry_intent()
      assert {:ok, :controlled} = Pipeline.classify_intent(intent)
    end

    test "classifies maintenance intents as safe" do
      intent = new_maintenance_intent()
      assert {:ok, :safe} = Pipeline.classify_intent(intent)
    end

    test "handles atom capability/operation values in payload" do
      source = @valid_source

      {:ok, intent} =
        Intent.new_action(source,
          summary: "Deploy app",
          payload: %{"capability" => :fly, "operation" => :deploy},
          affected_resources: ["fly-app"],
          expected_side_effects: ["app restarted"]
        )

      assert {:ok, :dangerous} = Pipeline.classify_intent(intent)
    end
  end

  # ── Telemetry Events ───────────────────────────────────────────────

  describe "telemetry" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler_id = "pipeline-telemetry-test-#{inspect(ref)}"

      events = [
        [:lattice, :intent, :proposed],
        [:lattice, :intent, :classified],
        [:lattice, :intent, :approved],
        [:lattice, :intent, :awaiting_approval],
        [:lattice, :intent, :rejected],
        [:lattice, :intent, :canceled]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, ref, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{ref: ref}
    end

    test "emits :proposed, :classified, :approved for safe intent", %{ref: ref} do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")
      {:ok, _} = Pipeline.propose(intent)

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :proposed], _, %{intent: proposed}}
      assert proposed.state == :proposed

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :classified], _,
                      %{intent: classified}}

      assert classified.state == :classified
      assert classified.classification == :safe

      assert_receive {:telemetry, ^ref, [:lattice, :intent, :approved], _, %{intent: approved}}
      assert approved.state == :approved
    end

    test "emits :proposed, :classified, :awaiting_approval for controlled intent", %{ref: ref} do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, _} = Pipeline.propose(intent)

          assert_receive {:telemetry, ^ref, [:lattice, :intent, :proposed], _, _}
          assert_receive {:telemetry, ^ref, [:lattice, :intent, :classified], _, _}

          assert_receive {:telemetry, ^ref, [:lattice, :intent, :awaiting_approval], _,
                          %{intent: awaiting}}

          assert awaiting.state == :awaiting_approval
        end
      )
    end

    test "emits :rejected on reject", %{ref: ref} do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)

          # Drain pipeline events
          assert_receive {:telemetry, ^ref, [:lattice, :intent, :proposed], _, _}
          assert_receive {:telemetry, ^ref, [:lattice, :intent, :classified], _, _}
          assert_receive {:telemetry, ^ref, [:lattice, :intent, :awaiting_approval], _, _}

          {:ok, _} = Pipeline.reject(awaiting.id, actor: "reviewer")

          assert_receive {:telemetry, ^ref, [:lattice, :intent, :rejected], _,
                          %{intent: rejected}}

          assert rejected.state == :rejected
        end
      )
    end

    test "emits :canceled on cancel", %{ref: ref} do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)

          # Drain pipeline events
          assert_receive {:telemetry, ^ref, [:lattice, :intent, :proposed], _, _}
          assert_receive {:telemetry, ^ref, [:lattice, :intent, :classified], _, _}
          assert_receive {:telemetry, ^ref, [:lattice, :intent, :awaiting_approval], _, _}

          {:ok, _} = Pipeline.cancel(awaiting.id, actor: "operator")

          assert_receive {:telemetry, ^ref, [:lattice, :intent, :canceled], _,
                          %{intent: canceled}}

          assert canceled.state == :canceled
        end
      )
    end

    test "emits :approved on manual approve", %{ref: ref} do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)

          # Drain pipeline events
          assert_receive {:telemetry, ^ref, [:lattice, :intent, :proposed], _, _}
          assert_receive {:telemetry, ^ref, [:lattice, :intent, :classified], _, _}
          assert_receive {:telemetry, ^ref, [:lattice, :intent, :awaiting_approval], _, _}

          {:ok, _} = Pipeline.approve(awaiting.id, actor: "reviewer")

          assert_receive {:telemetry, ^ref, [:lattice, :intent, :approved], _,
                          %{intent: approved}}

          assert approved.state == :approved
        end
      )
    end
  end

  # ── PubSub Broadcasts ─────────────────────────────────────────────

  describe "PubSub" do
    test "broadcasts on intent-specific and all-intents topics for safe intent" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")

      # Subscribe to both topics before proposing
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:#{intent.id}")
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:all")

      {:ok, _} = Pipeline.propose(intent)

      # Per-intent topic
      assert_receive {:intent_proposed, proposed}
      assert proposed.id == intent.id

      assert_receive {:intent_classified, classified}
      assert classified.classification == :safe

      assert_receive {:intent_approved, approved}
      assert approved.state == :approved

      # All-intents topic (same messages duplicated)
      assert_receive {:intent_proposed, _}
      assert_receive {:intent_classified, _}
      assert_receive {:intent_approved, _}
    end

    test "broadcasts awaiting_approval for controlled intent" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")

          Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:#{intent.id}")

          {:ok, _} = Pipeline.propose(intent)

          assert_receive {:intent_proposed, _}
          assert_receive {:intent_classified, _}
          assert_receive {:intent_awaiting_approval, awaiting}
          assert awaiting.state == :awaiting_approval
        end
      )
    end

    test "broadcasts on approve" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)

          Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:#{awaiting.id}")

          {:ok, _} = Pipeline.approve(awaiting.id, actor: "reviewer")

          assert_receive {:intent_approved, approved}
          assert approved.state == :approved
        end
      )
    end

    test "broadcasts on reject" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)

          Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:#{awaiting.id}")

          {:ok, _} = Pipeline.reject(awaiting.id, actor: "reviewer", reason: "nope")

          assert_receive {:intent_rejected, rejected}
          assert rejected.state == :rejected
        end
      )
    end

    test "broadcasts on cancel" do
      with_guardrails(
        [allow_controlled: true, require_approval_for_controlled: true],
        fn ->
          intent = new_action_intent(capability: "sprites", operation: "wake")
          {:ok, awaiting} = Pipeline.propose(intent)

          Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:#{awaiting.id}")

          {:ok, _} = Pipeline.cancel(awaiting.id, actor: "operator")

          assert_receive {:intent_canceled, canceled}
          assert canceled.state == :canceled
        end
      )
    end
  end

  # ── Edge Cases ─────────────────────────────────────────────────────

  describe "edge cases" do
    test "cannot approve an already-approved intent" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")
      {:ok, approved} = Pipeline.propose(intent)
      assert approved.state == :approved

      assert {:error, {:invalid_transition, _}} =
               Pipeline.approve(approved.id, actor: "human")
    end

    test "cannot reject an approved intent" do
      intent = new_action_intent(capability: "sprites", operation: "list_sprites")
      {:ok, approved} = Pipeline.propose(intent)

      assert {:error, {:invalid_transition, _}} =
               Pipeline.reject(approved.id, actor: "human")
    end

    test "approve returns not_found for missing intent" do
      assert {:error, :not_found} = Pipeline.approve("nonexistent", actor: "human")
    end

    test "reject returns not_found for missing intent" do
      assert {:error, :not_found} = Pipeline.reject("nonexistent", actor: "human")
    end

    test "cancel returns not_found for missing intent" do
      assert {:error, :not_found} = Pipeline.cancel("nonexistent", actor: "operator")
    end

    test "dangerous intent with allow_dangerous: false still goes to awaiting_approval" do
      with_guardrails(
        [allow_dangerous: false],
        fn ->
          intent = new_action_intent(capability: "fly", operation: "deploy")
          {:ok, result} = Pipeline.propose(intent)

          # When action_not_permitted, pipeline still routes to awaiting_approval
          # so a human can override the policy if needed
          assert result.state == :awaiting_approval
          assert result.classification == :dangerous
        end
      )
    end
  end
end
