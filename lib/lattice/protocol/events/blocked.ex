defmodule Lattice.Protocol.Events.Blocked do
  @moduledoc """
  Structured data for blocked events emitted by sprites.
  """

  defstruct [:reason]

  def from_map(map) do
    %__MODULE__{reason: Map.get(map, "reason")}
  end
end
