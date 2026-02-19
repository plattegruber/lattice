defmodule Lattice.Intents.Kind.PrFixup do
  @moduledoc "Respond to PR review feedback with follow-up commits."

  @behaviour Lattice.Intents.Kind

  @impl true
  def name, do: :pr_fixup

  @impl true
  def description, do: "PR Fixup"

  @impl true
  def required_payload_fields, do: ["pr_url", "feedback"]

  @impl true
  def default_classification, do: :controlled
end
