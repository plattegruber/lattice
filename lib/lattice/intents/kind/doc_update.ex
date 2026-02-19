defmodule Lattice.Intents.Kind.DocUpdate do
  @moduledoc """
  Intent kind for documentation updates.

  Created when documentation drift is detected — code changes have been made
  that require corresponding documentation updates.
  """

  @behaviour Lattice.Intents.Kind

  @impl true
  def name, do: :doc_update

  @impl true
  def description, do: "Documentation Update"

  @impl true
  def required_payload_fields, do: ["repo", "reason", "affected_docs"]

  @impl true
  def default_classification, do: :safe
end
