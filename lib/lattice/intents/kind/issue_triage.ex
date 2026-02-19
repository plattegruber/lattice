defmodule Lattice.Intents.Kind.IssueTriage do
  @moduledoc "Parse an issue, ask clarifying questions, or propose a plan."

  @behaviour Lattice.Intents.Kind

  @impl true
  def name, do: :issue_triage

  @impl true
  def description, do: "Issue Triage"

  @impl true
  def required_payload_fields, do: ["issue_url"]

  @impl true
  def default_classification, do: :controlled
end
