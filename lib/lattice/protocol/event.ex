defmodule Lattice.Protocol.Event do
  @moduledoc """
  Envelope for structured events emitted by sprites via the LATTICE_EVENT protocol.
  """

  @type t :: %__MODULE__{
          type: String.t(),
          timestamp: DateTime.t(),
          run_id: String.t() | nil,
          data: struct() | map()
        }

  @enforce_keys [:type, :timestamp, :data]
  defstruct [:type, :timestamp, :run_id, :data]

  def new(type, data, opts \\ []) do
    %__MODULE__{
      type: type,
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      run_id: Keyword.get(opts, :run_id),
      data: data
    }
  end
end
