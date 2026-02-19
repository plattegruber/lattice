defmodule Lattice.Protocol.Events.Progress do
  @moduledoc """
  Structured data for progress events emitted by sprites.
  """

  defstruct [:message, :percent, :phase]

  def from_map(map) do
    %__MODULE__{
      message: Map.get(map, "message"),
      percent: Map.get(map, "percent"),
      phase: Map.get(map, "phase")
    }
  end
end
