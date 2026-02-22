defmodule Lattice.Protocol.Events.PhaseStarted do
  @moduledoc """
  Protocol v1 PHASE_STARTED event. Sprite entered a logical phase of work.
  """

  defstruct [:phase]

  def from_map(map) do
    %__MODULE__{phase: Map.get(map, "phase")}
  end
end
