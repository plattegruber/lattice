defmodule Lattice.Protocol.EventHandler do
  @moduledoc """
  Wires protocol events from ExecSession into Run state updates.

  Subscribes to exec session event topics and routes events to the
  appropriate handlers (artifact storage, run state transitions, etc.).
  """

  require Logger

  alias Lattice.Protocol.Event
  alias Lattice.Protocol.Events.Artifact
  alias Lattice.Protocol.Events.Assumption
  alias Lattice.Protocol.Events.Blocked
  alias Lattice.Protocol.Events.Question
  alias Lattice.Runs.Run

  @doc """
  Handle a protocol event in the context of a run.
  Returns {:ok, updated_run} or {:error, reason}.
  """
  @spec handle_event(Event.t(), Run.t()) :: {:ok, Run.t()} | {:error, term()}
  def handle_event(%Event{type: "artifact", data: %Artifact{} = artifact_data}, %Run{} = run) do
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

    {:ok, updated_run}
  end

  def handle_event(%Event{type: "assumption", data: %Assumption{} = a}, %Run{} = run) do
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

  def handle_event(%Event{type: "question", data: %Question{} = q}, %Run{} = run) do
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

  def handle_event(%Event{type: "blocked", data: %Blocked{} = b}, %Run{} = run) do
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

  def handle_event(%Event{}, %Run{} = run) do
    # Other event types handled by their respective modules
    {:ok, run}
  end
end
