defmodule Lattice.Protocol.Events.Checkpoint do
  @moduledoc """
  Structured data for checkpoint events emitted by sprites.
  """

  defstruct [:message, metadata: %{}]

  def from_map(map) do
    %__MODULE__{
      message: Map.get(map, "message"),
      metadata: Map.get(map, "metadata", %{})
    }
  end
end
