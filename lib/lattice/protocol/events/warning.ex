defmodule Lattice.Protocol.Events.Warning do
  @moduledoc """
  Structured data for warning events emitted by sprites.
  """

  defstruct [:message, :details]

  def from_map(map) do
    %__MODULE__{
      message: Map.get(map, "message"),
      details: Map.get(map, "details")
    }
  end
end
