defmodule Lattice.Protocol.Events.PhaseFinished do
  @moduledoc """
  Protocol v1 PHASE_FINISHED event. Sprite completed a logical phase.
  """

  defstruct [:phase, success: true]

  def from_map(map) do
    %__MODULE__{
      phase: Map.get(map, "phase"),
      success: Map.get(map, "success", true)
    }
  end
end
