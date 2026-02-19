defmodule Lattice.Intents.Kind.Maintenance do
  @moduledoc "Built-in kind: proposes system improvements (update base image, pin dependency)."

  @behaviour Lattice.Intents.Kind

  @impl true
  def name, do: :maintenance

  @impl true
  def description, do: "Maintenance"

  @impl true
  def required_payload_fields, do: []

  @impl true
  def default_classification, do: :safe
end
