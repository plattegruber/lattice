defmodule Lattice.Intents.Executor.TaskTest do
  use ExUnit.Case

  @moduletag :unit

  import Mox

  alias Lattice.Intents.ExecutionResult
  alias Lattice.Intents.Executor.Router
  alias Lattice.Intents.Executor.Runner
  alias Lattice.Intents.Executor.Task, as: TaskExecutor
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Store
  alias Lattice.Intents.Store.ETS, as: StoreETS

  setup :verify_on_exit!

  # ── Helpers ──────────────────────────────────────────────────────────

  defp task_intent(opts \\ []) do
    sprite_name = Keyword.get(opts, :sprite_name, "atlas")
    repo = Keyword.get(opts, :repo, "plattegruber/webapp")
    source = Keyword.get(opts, :source, %{type: :sprite, id: "sprite-001"})

    {:ok, intent} =
      Intent.new_task(
        source,
        sprite_name,
        repo,
        task_kind: Keyword.get(opts, :task_kind, "open_pr_trivial_change"),
        instructions: Keyword.get(opts, :instructions, "Add a README file"),
        base_branch: Keyword.get(opts, :base_branch, "main"),
        pr_title: Keyword.get(opts, :pr_title),
        pr_body: Keyword.get(opts, :pr_body)
      )

    intent
  end

  defp regular_sprite_action do
    {:ok, intent} =
      Intent.new_action(
        %{type: :sprite, id: "sprite-001"},
        summary: "List sprites",
        payload: %{
          "capability" => "sprites",
          "operation" => "list_sprites",
          "args" => []
        },
        affected_resources: ["sprites"],
        expected_side_effects: ["none"]
      )

    intent
  end

  defp operator_action_intent do
    {:ok, intent} =
      Intent.new_action(
        %{type: :operator, id: "op-001"},
        summary: "Operator action",
        payload: %{"capability" => "sprites", "operation" => "list_sprites"},
        affected_resources: ["sprites"],
        expected_side_effects: ["none"]
      )

    intent
  end

  defp maintenance_intent do
    {:ok, intent} =
      Intent.new_maintenance(
        %{type: :sprite, id: "sprite-001"},
        summary: "Update base image",
        payload: %{"capability" => "fly", "operation" => "deploy"}
      )

    intent
  end

  defp inquiry_intent do
    {:ok, intent} =
      Intent.new_inquiry(
        %{type: :operator, id: "op-001"},
        summary: "Need API key",
        payload: %{
          "what_requested" => "API key",
          "why_needed" => "Integration",
          "scope_of_impact" => "single service",
          "expiration" => "2026-03-01"
        }
      )

    intent
  end

  defp task_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "capability" => "sprites",
        "operation" => "run_task",
        "sprite_name" => "atlas",
        "repo" => "plattegruber/webapp",
        "base_branch" => "main",
        "task_kind" => "open_pr_trivial_change",
        "instructions" => "Add a README file"
      },
      overrides
    )
  end

  defp exec_result_with_pr_url(sprite_name \\ "atlas") do
    output =
      "Cloning into 'task-repo'...\nLATTICE_PR_URL=https://github.com/plattegruber/webapp/pull/42\n{\"pr_url\": \"https://github.com/plattegruber/webapp/pull/42\"}"

    {:ok,
     %{
       sprite_id: sprite_name,
       command: "bash script",
       output: output,
       exit_code: 0
     }}
  end

  defp exec_result_without_pr_url(sprite_name \\ "atlas") do
    {:ok,
     %{
       sprite_id: sprite_name,
       command: "bash script",
       output: "Cloning...\nDone.\nNo PR created.",
       exit_code: 0
     }}
  end

  defp exec_result_failure(sprite_name \\ "atlas") do
    {:ok,
     %{
       sprite_id: sprite_name,
       command: "bash script",
       output: "fatal: repository not found",
       exit_code: 128
     }}
  end

  # ── can_execute?/1 ──────────────────────────────────────────────────

  describe "can_execute?/1" do
    test "returns true for task intents" do
      intent = task_intent()

      assert TaskExecutor.can_execute?(intent) == true
    end

    test "returns true for task intents from any source type" do
      for source_type <- [:sprite, :operator, :cron, :agent] do
        intent = task_intent(source: %{type: source_type, id: "#{source_type}-001"})

        assert TaskExecutor.can_execute?(intent) == true,
               "Expected can_execute? to return true for source type #{source_type}"
      end
    end

    test "returns false for regular sprite action intents" do
      intent = regular_sprite_action()

      assert TaskExecutor.can_execute?(intent) == false
    end

    test "returns false for operator action intents" do
      intent = operator_action_intent()

      assert TaskExecutor.can_execute?(intent) == false
    end

    test "returns false for maintenance intents" do
      intent = maintenance_intent()

      assert TaskExecutor.can_execute?(intent) == false
    end

    test "returns false for inquiry intents" do
      intent = inquiry_intent()

      assert TaskExecutor.can_execute?(intent) == false
    end
  end

  # ── build_script/1 ──────────────────────────────────────────────────

  describe "build_script/1" do
    test "builds script with required payload fields" do
      payload = task_payload()
      script = TaskExecutor.build_script(payload)

      assert script =~ "git clone"
      assert script =~ "plattegruber/webapp"
      assert script =~ "origin/main"
      assert script =~ "open_pr_trivial_change"
      assert script =~ "Add a README file"
      assert script =~ "gh pr create"
      assert script =~ "LATTICE_PR_URL"
      assert script =~ "set -euo pipefail"
    end

    test "uses custom base_branch" do
      payload = task_payload(%{"base_branch" => "develop"})
      script = TaskExecutor.build_script(payload)

      assert script =~ "origin/develop"
      assert script =~ "--base 'develop'"
    end

    test "uses custom pr_title" do
      payload = task_payload(%{"pr_title" => "My Custom Title"})
      script = TaskExecutor.build_script(payload)

      assert script =~ "My Custom Title"
    end

    test "uses custom pr_body" do
      payload = task_payload(%{"pr_body" => "Custom PR body text"})
      script = TaskExecutor.build_script(payload)

      assert script =~ "Custom PR body text"
    end

    test "defaults pr_title when not provided" do
      payload = task_payload()
      script = TaskExecutor.build_script(payload)

      assert script =~ "Task: open_pr_trivial_change"
    end

    test "defaults pr_body when not provided" do
      payload = task_payload()
      script = TaskExecutor.build_script(payload)

      assert script =~ "Automated task: open_pr_trivial_change"
    end

    test "generates branch name with task_kind prefix" do
      payload = task_payload()
      script = TaskExecutor.build_script(payload)

      assert script =~ "lattice/open_pr_trivial_change-"
    end

    test "writes instructions via heredoc instead of echo" do
      payload = task_payload()
      script = TaskExecutor.build_script(payload)

      assert script =~ "cat > .lattice-task <<'"
      # The instructions should not be written via echo, but via a heredoc.
      # (There are other echo statements for the output contract and errors.)
      refute script =~ ~s(echo "Add a README file")
    end

    test "cleans up previous task-repo directory" do
      payload = task_payload()
      script = TaskExecutor.build_script(payload)

      assert script =~ "rm -rf task-repo"
    end

    test "passes --repo flag to gh pr create" do
      payload = task_payload()
      script = TaskExecutor.build_script(payload)

      assert script =~ "--repo 'plattegruber/webapp'"
    end

    test "validates PR URL was captured" do
      payload = task_payload()
      script = TaskExecutor.build_script(payload)

      assert script =~ ~s(if [ -z "${PR_URL}" ])
      assert script =~ "exit 1"
    end

    test "escapes single quotes in pr_title" do
      payload = task_payload(%{"pr_title" => "It's a test"})
      script = TaskExecutor.build_script(payload)

      assert script =~ "It'\\''s a test"
    end

    test "escapes single quotes in pr_body" do
      payload = task_payload(%{"pr_body" => "Body with 'quotes'"})
      script = TaskExecutor.build_script(payload)

      assert script =~ "'\\''quotes'\\''", "Expected escaped single quotes in pr_body"
    end

    test "handles instructions with shell metacharacters safely" do
      payload =
        task_payload(%{
          "instructions" => "Run $(dangerous-command) and `backtick` and $VARIABLE"
        })

      script = TaskExecutor.build_script(payload)

      # Instructions should be inside a heredoc with single-quoted delimiter,
      # which prevents shell expansion
      assert script =~ "<<'"
      assert script =~ "$(dangerous-command)"
    end

    test "handles multiline instructions" do
      payload =
        task_payload(%{
          "instructions" => "Line one\nLine two\nLine three"
        })

      script = TaskExecutor.build_script(payload)

      # Should contain the multiline instructions within the heredoc
      assert script =~ "Line one\nLine two\nLine three"
    end

    test "outputs JSON with pr_url on stdout" do
      payload = task_payload()
      script = TaskExecutor.build_script(payload)

      assert script =~ ~s(echo '{"pr_url": "'"${PR_URL}"'"}')
    end
  end

  # ── escape_single_quotes/1 ──────────────────────────────────────────

  describe "escape_single_quotes/1" do
    test "returns string unchanged when no single quotes" do
      assert TaskExecutor.escape_single_quotes("hello world") == "hello world"
    end

    test "escapes a single quote" do
      assert TaskExecutor.escape_single_quotes("it's") == "it'\\''s"
    end

    test "escapes multiple single quotes" do
      assert TaskExecutor.escape_single_quotes("it's a 'test'") == "it'\\''s a '\\''test'\\''"
    end

    test "handles empty string" do
      assert TaskExecutor.escape_single_quotes("") == ""
    end

    test "does not alter double quotes" do
      assert TaskExecutor.escape_single_quotes(~s(say "hello")) == ~s(say "hello")
    end
  end

  # ── parse_pr_url/1 ──────────────────────────────────────────────────

  describe "parse_pr_url/1" do
    test "extracts PR URL from output" do
      output = "LATTICE_PR_URL=https://github.com/plattegruber/webapp/pull/42\n"

      assert TaskExecutor.parse_pr_url(output) ==
               "https://github.com/plattegruber/webapp/pull/42"
    end

    test "extracts PR URL from JSON output" do
      output = ~s({"pr_url": "https://github.com/plattegruber/webapp/pull/99"})

      assert TaskExecutor.parse_pr_url(output) ==
               "https://github.com/plattegruber/webapp/pull/99"
    end

    test "extracts first PR URL when multiple are present" do
      output = """
      https://github.com/plattegruber/webapp/pull/42
      https://github.com/plattegruber/webapp/pull/43
      """

      assert TaskExecutor.parse_pr_url(output) ==
               "https://github.com/plattegruber/webapp/pull/42"
    end

    test "returns nil when no PR URL is present" do
      assert TaskExecutor.parse_pr_url("just some output\nno urls here") == nil
    end

    test "returns nil for empty string" do
      assert TaskExecutor.parse_pr_url("") == nil
    end

    test "returns nil for non-string input" do
      assert TaskExecutor.parse_pr_url(nil) == nil
      assert TaskExecutor.parse_pr_url(42) == nil
    end

    test "handles PR URLs with large numbers" do
      output = "https://github.com/org/repo/pull/12345"

      assert TaskExecutor.parse_pr_url(output) ==
               "https://github.com/org/repo/pull/12345"
    end
  end

  # ── execute/1 ──────────────────────────────────────────────────────

  describe "execute/1" do
    test "successful execution with PR URL returns success result with artifact" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", command ->
        assert command =~ "git clone"
        assert command =~ "plattegruber/webapp"
        exec_result_with_pr_url()
      end)

      intent = task_intent()

      assert {:ok, %ExecutionResult{status: :success} = result} = TaskExecutor.execute(intent)
      assert result.executor == Lattice.Intents.Executor.Task
      assert result.duration_ms >= 0
      assert %DateTime{} = result.started_at
      assert %DateTime{} = result.completed_at
      assert length(result.artifacts) == 1

      [artifact] = result.artifacts
      assert artifact.type == "pr_url"
      assert artifact.data == "https://github.com/plattegruber/webapp/pull/42"
    end

    test "successful execution without PR URL returns success with no artifacts" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _command ->
        exec_result_without_pr_url()
      end)

      intent = task_intent()

      assert {:ok, %ExecutionResult{status: :success} = result} = TaskExecutor.execute(intent)
      assert result.artifacts == []
    end

    test "nonzero exit code returns failure result" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _command ->
        exec_result_failure()
      end)

      intent = task_intent()

      assert {:ok, %ExecutionResult{status: :failure} = result} = TaskExecutor.execute(intent)
      assert result.error == {:nonzero_exit, 128}
      assert result.executor == Lattice.Intents.Executor.Task
    end

    test "capability error returns failure result" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _command ->
        {:error, :not_found}
      end)

      intent = task_intent()

      assert {:ok, %ExecutionResult{status: :failure} = result} = TaskExecutor.execute(intent)
      assert result.error == :not_found
      assert result.executor == Lattice.Intents.Executor.Task
    end

    test "uses sprite_name from payload for exec call" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "beacon", _command ->
        exec_result_with_pr_url("beacon")
      end)

      intent = task_intent(sprite_name: "beacon")

      assert {:ok, %ExecutionResult{status: :success}} = TaskExecutor.execute(intent)
    end

    test "tracks execution timing" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _command ->
        Process.sleep(10)
        exec_result_with_pr_url()
      end)

      intent = task_intent()

      assert {:ok, %ExecutionResult{} = result} = TaskExecutor.execute(intent)
      assert result.duration_ms >= 10
      assert DateTime.compare(result.completed_at, result.started_at) in [:gt, :eq]
    end

    test "includes exec output in result" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _command ->
        exec_result_with_pr_url()
      end)

      intent = task_intent()

      assert {:ok, %ExecutionResult{status: :success} = result} = TaskExecutor.execute(intent)
      assert result.output.sprite_id == "atlas"
      assert result.output.exit_code == 0
      assert is_binary(result.output.output)
    end
  end

  # ── PubSub Log Broadcasting ────────────────────────────────────────

  describe "PubSub log broadcasting" do
    test "broadcasts task log lines on intent topic" do
      intent = task_intent()
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:#{intent.id}")

      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _command ->
        exec_result_with_pr_url()
      end)

      {:ok, _result} = TaskExecutor.execute(intent)

      assert_receive {:intent_task_log, intent_id, lines}
      assert intent_id == intent.id
      assert is_list(lines)
      assert lines != []
    end

    test "does not broadcast when output is not a string" do
      # This tests the guard clause -- non-string output should not crash
      intent = task_intent()
      Phoenix.PubSub.subscribe(Lattice.PubSub, "intents:#{intent.id}")

      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _command ->
        {:error, :api_timeout}
      end)

      {:ok, _result} = TaskExecutor.execute(intent)

      refute_receive {:intent_task_log, _, _}, 100
    end
  end

  # ── Router Integration ─────────────────────────────────────────────

  describe "Router integration" do
    test "task intent routes to Task executor" do
      intent = task_intent()

      assert {:ok, TaskExecutor} = Router.route(intent)
    end

    test "task intent takes priority over Sprite executor" do
      # A task intent from a sprite would match both Task and Sprite executors.
      # Task must win because it is registered first.
      intent = task_intent(source: %{type: :sprite, id: "sprite-001"})

      assert {:ok, TaskExecutor} = Router.route(intent)
    end

    test "regular sprite action still routes to Sprite executor" do
      intent = regular_sprite_action()

      assert {:ok, Lattice.Intents.Executor.Sprite} = Router.route(intent)
    end

    test "Task executor is in the executors list" do
      assert TaskExecutor in Router.executors()
    end
  end

  # ── Full Runner Integration ────────────────────────────────────────

  describe "Runner integration" do
    setup do
      StoreETS.reset()
      :ok
    end

    test "runs task intent through full pipeline to completed" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", command ->
        assert command =~ "git clone"
        exec_result_with_pr_url()
      end)

      intent = task_intent()

      {:ok, _stored} = Store.create(intent)
      {:ok, _classified} = Store.update(intent.id, %{state: :classified, classification: :safe})
      {:ok, _approved} = Store.update(intent.id, %{state: :approved, actor: :test})

      assert {:ok, completed} = Runner.run(intent.id)
      assert completed.state == :completed
      assert completed.result.status == :success
      assert completed.result.executor == Lattice.Intents.Executor.Task
    end

    test "stores PR URL artifact on intent" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _command ->
        exec_result_with_pr_url()
      end)

      intent = task_intent()

      {:ok, _stored} = Store.create(intent)
      {:ok, _classified} = Store.update(intent.id, %{state: :classified, classification: :safe})
      {:ok, _approved} = Store.update(intent.id, %{state: :approved, actor: :test})

      {:ok, _completed} = Runner.run(intent.id)

      {:ok, fetched} = Store.get(intent.id)
      artifacts = Map.get(fetched.metadata, :artifacts, [])
      assert length(artifacts) == 1
      assert hd(artifacts).type == "pr_url"
      assert hd(artifacts).data == "https://github.com/plattegruber/webapp/pull/42"
    end

    test "marks intent failed on exec error" do
      Lattice.Capabilities.MockSprites
      |> expect(:exec, fn "atlas", _command ->
        {:error, :not_found}
      end)

      intent = task_intent()

      {:ok, _stored} = Store.create(intent)
      {:ok, _classified} = Store.update(intent.id, %{state: :classified, classification: :safe})
      {:ok, _approved} = Store.update(intent.id, %{state: :approved, actor: :test})

      assert {:ok, failed} = Runner.run(intent.id)
      assert failed.state == :failed
      assert failed.result.status == :failure
    end
  end
end
