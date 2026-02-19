defmodule Lattice.Intents.Kind.Action do
  @moduledoc "Built-in kind: produces side effects (deploy, modify infrastructure, scale fleet)."

  @behaviour Lattice.Intents.Kind

  @impl true
  def name, do: :action

  @impl true
  def description, do: "Action"

  @impl true
  def required_payload_fields, do: ["capability", "operation"]

  @impl true
  def default_classification, do: :controlled
end
