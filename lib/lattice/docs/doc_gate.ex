defmodule Lattice.Docs.DocGate do
  @moduledoc """
  Gate that checks whether completed intents need corresponding documentation
  updates before they should be considered fully resolved.

  Works with repo profiles to determine doc requirements per change type.
  Can propose `doc_update` intents when drift is detected.

  ## Configuration

      config :lattice, Lattice.Docs.DocGate,
        enabled: true,
        auto_propose: true
  """

  require Logger

  alias Lattice.Docs.DriftDetector
  alias Lattice.Intents.Intent
  alias Lattice.Intents.Pipeline
  alias Lattice.Policy.RepoProfile

  @doc """
  Check if an intent needs a doc update. Returns `:ok` or `{:needs_docs, drift}`.
  """
  @spec check(Intent.t()) :: :ok | {:needs_docs, map()}
  def check(%Intent{} = intent) do
    if enabled?() do
      case DriftDetector.check_intent(intent) do
        nil -> :ok
        drift -> {:needs_docs, drift}
      end
    else
      :ok
    end
  end

  @doc """
  Propose a doc_update intent for a detected drift.
  """
  @spec propose_doc_update(map()) :: {:ok, Intent.t()} | {:error, term()}
  def propose_doc_update(drift) do
    {:ok, intent} =
      Intent.new_action(%{type: :system, id: "doc-gate"},
        summary: "Documentation update needed: #{drift.reason}",
        payload: %{
          "repo" => drift.repo,
          "reason" => drift.reason,
          "affected_docs" => drift.affected_docs,
          "source_intent_id" => drift.intent_id,
          "change_type" => to_string(drift.change_type)
        },
        affected_resources: drift.affected_docs,
        expected_side_effects: ["documentation_update"]
      )

    intent = %{intent | kind: :doc_update}
    Pipeline.propose(intent)
  end

  @doc """
  Track documentation freshness for key files in a repo.
  Returns a map of file paths to their staleness status.
  """
  @spec check_freshness(String.t()) :: %{String.t() => :fresh | :stale | :unknown}
  def check_freshness(repo) do
    profile = RepoProfile.get_or_default(repo)
    key_files = ["CLAUDE.md", "README.md" | profile.doc_paths]

    Map.new(key_files, fn path ->
      {path, :unknown}
    end)
  end

  defp enabled? do
    Application.get_env(:lattice, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end
end
