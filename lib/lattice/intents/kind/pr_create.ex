defmodule Lattice.Intents.Kind.PrCreate do
  @moduledoc "Create a PR from an approved plan."

  @behaviour Lattice.Intents.Kind

  @impl true
  def name, do: :pr_create

  @impl true
  def description, do: "PR Create"

  @impl true
  def required_payload_fields, do: ["repo", "branch"]

  @impl true
  def default_classification, do: :controlled
end
