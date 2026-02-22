defmodule Lattice.Protocol.Events.Waiting do
  @moduledoc """
  Protocol v1 WAITING event. Sprite has reached a blocking point and
  cannot proceed without external input.

  The sprite MUST create a checkpoint before emitting this event and
  include the checkpoint_id. After emitting WAITING, the sprite stops work.
  Lattice owns continuation via checkpoint restore + exec.
  """

  defstruct [:reason, :checkpoint_id, expected_inputs: %{}]

  def from_map(map) do
    %__MODULE__{
      reason: Map.get(map, "reason"),
      checkpoint_id: Map.get(map, "checkpoint_id"),
      expected_inputs: Map.get(map, "expected_inputs", %{})
    }
  end
end
