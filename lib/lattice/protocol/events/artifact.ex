defmodule Lattice.Protocol.Events.Artifact do
  @moduledoc """
  Structured data for artifact events emitted by sprites.
  """

  defstruct [:kind, :url, metadata: %{}]

  def from_map(map) do
    %__MODULE__{
      kind: Map.get(map, "kind"),
      url: Map.get(map, "url"),
      metadata: Map.get(map, "metadata", %{})
    }
  end
end
