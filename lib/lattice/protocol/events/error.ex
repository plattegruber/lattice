defmodule Lattice.Protocol.Events.Error do
  @moduledoc """
  Protocol v1 ERROR event. Unrecoverable failure.
  """

  defstruct [:message, details: %{}]

  def from_map(map) do
    %__MODULE__{
      message: Map.get(map, "message"),
      details: Map.get(map, "details", %{})
    }
  end
end
