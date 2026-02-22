defmodule Lattice.Protocol.Events.ActionRequest do
  @moduledoc """
  Protocol v1 ACTION_REQUEST event. Sprite requests Lattice perform an
  external action on its behalf.

  When `blocking` is true, the sprite will emit a WAITING event immediately
  after and expects the action result in the resume payload.
  """

  defstruct [:action, parameters: %{}, blocking: false]

  def from_map(map) do
    %__MODULE__{
      action: Map.get(map, "action"),
      parameters: Map.get(map, "parameters", %{}),
      blocking: Map.get(map, "blocking", false)
    }
  end
end
