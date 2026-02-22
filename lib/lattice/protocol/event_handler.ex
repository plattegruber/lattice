defmodule Lattice.Protocol.EventHandler do
  @moduledoc """
  Wires protocol events from ExecSession into Run state updates.

  Handles both protocol v1 events and legacy event types. Routes events to
  the appropriate handlers (artifact storage, run state transitions, etc.).
  """

  require Logger

  alias Lattice.Capabilities.GitHub.ArtifactLink
  alias Lattice.Capabilities.GitHub.ArtifactRegistry
  alias Lattice.Protocol.Event

  # Legacy event structs
  alias Lattice.Protocol.Events.Artifact
  alias Lattice.Protocol.Events.Assumption
  alias Lattice.Protocol.Events.Blocked
  alias Lattice.Protocol.Events.Question

  # Protocol v1 event structs
  alias Lattice.Protocol.Events.ActionRequest
  alias Lattice.Protocol.Events.Completed
  alias Lattice.Protocol.Events.EnvironmentProposal
  alias Lattice.Protocol.Events.Error, as: ErrorEvent
  alias Lattice.Protocol.Events.Waiting

  alias Lattice.Runs.Run

  @doc """
  Handle a protocol event in the context of a run.
  Returns {:ok, updated_run} or {:error, reason}.
  """

  # ── Protocol v1: ARTIFACT (same struct as legacy, uppercase type) ────

  @spec handle_event(Event.t(), Run.t()) :: {:ok, Run.t()} | {:error, term()}
  def handle_event(%Event{event_type: type, data: %Artifact{} = artifact_data}, %Run{} = run)
      when type in ["artifact", "ARTIFACT"] do
    artifact = %{
      kind: artifact_data.kind,
      url: artifact_data.url,
      metadata: artifact_data.metadata
    }

    updated_run = Run.add_artifact(run, artifact)

    :telemetry.execute(
      [:lattice, :run, :artifact_added],
      %{count: 1},
      %{run_id: run.id, artifact_kind: artifact_data.kind}
    )

    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      "runs",
      {:run_artifact_added, updated_run, artifact}
    )

    maybe_register_github_artifact(run, artifact)

    {:ok, updated_run}
  end

  # ── Legacy: assumption ───────────────────────────────────────────────

  def handle_event(%Event{event_type: "assumption", data: %Assumption{} = a}, %Run{} = run) do
    updated =
      Enum.reduce(a.files, run, fn file, acc ->
        assumption = %{
          path: file.path,
          lines: file.lines,
          note: file.note,
          timestamp: DateTime.utc_now()
        }

        Run.add_assumption(acc, assumption)
      end)

    :telemetry.execute(
      [:lattice, :run, :assumption_recorded],
      %{count: length(a.files)},
      %{run_id: run.id}
    )

    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      "runs",
      {:run_assumption_added, updated}
    )

    {:ok, updated}
  end

  # ── Legacy: question → blocked_waiting_for_user ──────────────────────

  def handle_event(%Event{event_type: "question", data: %Question{} = q}, %Run{} = run) do
    question_data = %{prompt: q.prompt, choices: q.choices, default: q.default}

    case Run.block_for_input(run, question_data) do
      {:ok, updated} ->
        :telemetry.execute(
          [:lattice, :run, :question_asked],
          %{count: 1},
          %{run_id: run.id}
        )

        Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_blocked, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  # ── Legacy: blocked ──────────────────────────────────────────────────

  def handle_event(%Event{event_type: "blocked", data: %Blocked{} = b}, %Run{} = run) do
    case Run.block(run, b.reason) do
      {:ok, updated} ->
        :telemetry.execute(
          [:lattice, :run, :blocked],
          %{count: 1},
          %{run_id: run.id, reason: b.reason}
        )

        Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_blocked, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  # ── Protocol v1: WAITING → :waiting with checkpoint ──────────────────

  def handle_event(%Event{event_type: "WAITING", data: %Waiting{} = w}, %Run{} = run) do
    case Run.wait(run, w.reason, w.checkpoint_id, w.expected_inputs) do
      {:ok, updated} ->
        :telemetry.execute(
          [:lattice, :run, :waiting],
          %{count: 1},
          %{
            run_id: run.id,
            reason: w.reason,
            checkpoint_id: w.checkpoint_id
          }
        )

        Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_waiting, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  # ── Protocol v1: COMPLETED → succeed or fail ─────────────────────────

  def handle_event(%Event{event_type: "COMPLETED", data: %Completed{} = c}, %Run{} = run) do
    case c.status do
      "success" ->
        case Run.complete(run) do
          {:ok, updated} ->
            :telemetry.execute(
              [:lattice, :run, :completed],
              %{count: 1},
              %{run_id: run.id, status: "success"}
            )

            Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_completed, updated})
            {:ok, updated}

          error ->
            error
        end

      "failure" ->
        case Run.fail(run, %{error: c.summary}) do
          {:ok, updated} ->
            :telemetry.execute(
              [:lattice, :run, :completed],
              %{count: 1},
              %{run_id: run.id, status: "failure"}
            )

            Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_failed, updated})
            {:ok, updated}

          error ->
            error
        end

      _other ->
        {:ok, run}
    end
  end

  # ── Protocol v1: ERROR → fail ────────────────────────────────────────

  def handle_event(%Event{event_type: "ERROR", data: %ErrorEvent{} = e}, %Run{} = run) do
    case Run.fail(run, %{error: e.message}) do
      {:ok, updated} ->
        :telemetry.execute(
          [:lattice, :run, :error],
          %{count: 1},
          %{run_id: run.id, message: e.message}
        )

        Phoenix.PubSub.broadcast(Lattice.PubSub, "runs", {:run_failed, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  # ── Protocol v1: ACTION_REQUEST → dispatch ───────────────────────────

  def handle_event(%Event{event_type: "ACTION_REQUEST", data: %ActionRequest{} = a}, %Run{} = run) do
    :telemetry.execute(
      [:lattice, :run, :action_requested],
      %{count: 1},
      %{run_id: run.id, action: a.action, blocking: a.blocking}
    )

    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      "runs",
      {:action_requested, run, a}
    )

    # Non-blocking: run continues. Blocking: sprite will emit WAITING next.
    {:ok, run}
  end

  # ── Protocol v1: PHASE_STARTED / PHASE_FINISHED → telemetry ─────────

  def handle_event(%Event{event_type: "PHASE_STARTED", data: data}, %Run{} = run) do
    phase = Map.get(data, :phase) || Map.get(data, "phase")

    :telemetry.execute(
      [:lattice, :run, :phase_started],
      %{count: 1},
      %{run_id: run.id, phase: phase}
    )

    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      "runs",
      {:phase_started, run, phase}
    )

    {:ok, run}
  end

  def handle_event(%Event{event_type: "PHASE_FINISHED", data: data}, %Run{} = run) do
    phase = Map.get(data, :phase) || Map.get(data, "phase")
    success = Map.get(data, :success) || Map.get(data, "success", true)

    :telemetry.execute(
      [:lattice, :run, :phase_finished],
      %{count: 1},
      %{run_id: run.id, phase: phase, success: success}
    )

    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      "runs",
      {:phase_finished, run, phase, success}
    )

    {:ok, run}
  end

  # ── Protocol v1: INFO → telemetry (no state change) ─────────────────

  def handle_event(%Event{event_type: "INFO", data: data}, %Run{} = run) do
    message = Map.get(data, :message) || Map.get(data, "message")
    kind = Map.get(data, :kind) || Map.get(data, "kind")

    :telemetry.execute(
      [:lattice, :run, :info],
      %{count: 1},
      %{run_id: run.id, kind: kind}
    )

    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      "runs",
      {:run_info, run, %{message: message, kind: kind, data: data}}
    )

    {:ok, run}
  end

  # ── Protocol v1: ENVIRONMENT_PROPOSAL → broadcast for handling ───────

  def handle_event(
        %Event{event_type: "ENVIRONMENT_PROPOSAL", data: %EnvironmentProposal{} = p},
        %Run{} = run
      ) do
    :telemetry.execute(
      [:lattice, :run, :environment_proposal],
      %{count: 1},
      %{
        run_id: run.id,
        adjustment_type: get_in_map(p.suggested_adjustment, "type"),
        scope: p.scope,
        confidence: p.confidence
      }
    )

    Phoenix.PubSub.broadcast(
      Lattice.PubSub,
      "environment_proposals",
      {:environment_proposal, run, p}
    )

    {:ok, run}
  end

  # ── Catch-all: unknown events pass through ───────────────────────────

  def handle_event(%Event{}, %Run{} = run) do
    {:ok, run}
  end

  # ── Private: GitHub Artifact Registration ────────────────────────────

  @github_artifact_kinds %{
    "pr_url" => :pull_request,
    "pull_request" => :pull_request,
    "issue_url" => :issue,
    "issue" => :issue,
    "branch" => :branch,
    "commit" => :commit,
    "commit_sha" => :commit
  }

  defp maybe_register_github_artifact(%Run{} = run, artifact) do
    kind_str = to_string(artifact.kind)

    case Map.get(@github_artifact_kinds, kind_str) do
      nil ->
        :ok

      link_kind ->
        ref = extract_ref(link_kind, artifact)

        if ref do
          link =
            ArtifactLink.new(%{
              intent_id: run.intent_id,
              run_id: run.id,
              kind: link_kind,
              ref: ref,
              url: artifact.url,
              role: :output
            })

          ArtifactRegistry.register(link)
        end
    end
  rescue
    _ -> :ok
  end

  defp extract_ref(:pull_request, artifact), do: extract_number_from_url(artifact.url)
  defp extract_ref(:issue, artifact), do: extract_number_from_url(artifact.url)

  defp extract_ref(:branch, artifact),
    do: artifact.url || Map.get(artifact.metadata || %{}, :name)

  defp extract_ref(:commit, artifact), do: artifact.url || Map.get(artifact.metadata || %{}, :sha)

  defp extract_number_from_url(nil), do: nil

  defp extract_number_from_url(url) when is_binary(url) do
    case Regex.run(~r/\/(\d+)(?:$|\?)/, url) do
      [_, number] -> String.to_integer(number)
      _ -> url
    end
  end

  defp get_in_map(map, key) when is_map(map), do: Map.get(map, key)
  defp get_in_map(_, _), do: nil
end
