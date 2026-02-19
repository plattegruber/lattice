defmodule Lattice.Intents.Kind.Inquiry do
  @moduledoc "Built-in kind: requests human input or secrets."

  @behaviour Lattice.Intents.Kind

  @impl true
  def name, do: :inquiry

  @impl true
  def description, do: "Inquiry"

  @impl true
  def required_payload_fields,
    do: ["what_requested", "why_needed", "scope_of_impact", "expiration"]

  @impl true
  def default_classification, do: :controlled
end
