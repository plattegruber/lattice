defmodule Lattice.Intents.Kind.HealthDetect do
  @moduledoc """
  Intent kind for health detection signals.

  Represents a detected health issue that may require attention or
  auto-remediation. Created by the HealthDetector when observations
  meet severity thresholds.
  """

  @behaviour Lattice.Intents.Kind

  @impl true
  def name, do: :health_detect

  @impl true
  def description, do: "Health Detection"

  @impl true
  def required_payload_fields, do: ["observation_type", "severity", "sprite_id"]

  @impl true
  def default_classification, do: :safe
end
