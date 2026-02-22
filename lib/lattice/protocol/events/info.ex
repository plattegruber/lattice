defmodule Lattice.Protocol.Events.Info do
  @moduledoc """
  Protocol v1 INFO event. Non-blocking informational message.

  Supports optional `kind` and `metadata` for machine-actionable rendering
  while `message` provides a human-readable fallback.
  """

  defstruct [:message, :kind, metadata: %{}]

  def from_map(map) do
    %__MODULE__{
      message: Map.get(map, "message"),
      kind: Map.get(map, "kind"),
      metadata: Map.get(map, "metadata", %{})
    }
  end
end
