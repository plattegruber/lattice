defmodule Lattice.Protocol.Events.Assumption do
  @moduledoc """
  Structured data for assumption events emitted by sprites.
  """

  defstruct files: []

  def from_map(map) do
    files =
      Map.get(map, "files", [])
      |> Enum.map(fn f ->
        %{path: Map.get(f, "path"), lines: Map.get(f, "lines", []), note: Map.get(f, "note")}
      end)

    %__MODULE__{files: files}
  end
end
