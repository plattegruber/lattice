defmodule Lattice.Protocol.Events.Completion do
  @moduledoc """
  Structured data for completion events emitted by sprites.
  """

  defstruct [:status, :summary]

  def from_map(map) do
    %__MODULE__{
      status: Map.get(map, "status"),
      summary: Map.get(map, "summary")
    }
  end
end
