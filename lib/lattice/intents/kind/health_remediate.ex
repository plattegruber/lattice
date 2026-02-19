defmodule Lattice.Intents.Kind.HealthRemediate do
  @moduledoc """
  Intent kind for health auto-remediation.

  Represents a remediation action proposed in response to a health
  detection. Links to the originating health_detect intent and
  executes a fix (typically via the Task executor to create a PR).
  """

  @behaviour Lattice.Intents.Kind

  @impl true
  def name, do: :health_remediate

  @impl true
  def description, do: "Health Remediation"

  @impl true
  def required_payload_fields, do: ["detect_intent_id", "remediation_type"]

  @impl true
  def default_classification, do: :controlled
end
