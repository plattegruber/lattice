defmodule Lattice.Protocol.Events.Question do
  @moduledoc """
  Structured data for question events emitted by sprites.
  """

  defstruct [:prompt, :default, choices: []]

  def from_map(map) do
    %__MODULE__{
      prompt: Map.get(map, "prompt"),
      choices: Map.get(map, "choices", []),
      default: Map.get(map, "default")
    }
  end
end
