defmodule Lattice.Protocol.Events.Completed do
  @moduledoc """
  Protocol v1 COMPLETED event. Sprite has finished all work on the
  current work item.
  """

  defstruct [:status, :summary]

  def from_map(map) do
    %__MODULE__{
      status: Map.get(map, "status"),
      summary: Map.get(map, "summary")
    }
  end
end
