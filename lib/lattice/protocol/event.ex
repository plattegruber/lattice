defmodule Lattice.Protocol.Event do
  @moduledoc """
  Envelope for structured events emitted by sprites via the LATTICE_EVENT protocol.

  ## Protocol v1 Envelope

  Every event carries:
  - `protocol_version` — always `"v1"` for now
  - `event_type` — protocol-defined type (INFO, WAITING, COMPLETED, etc.)
  - `sprite_id` — which sprite emitted this event
  - `work_item_id` — external work reference (issue, PR, task)
  - `timestamp` — when the event was emitted
  - `data` — parsed, typed payload

  For backward compatibility, `type` aliases `event_type` and `run_id` aliases
  `work_item_id` when constructing events from pre-v1 sources.
  """

  @type t :: %__MODULE__{
          protocol_version: String.t(),
          event_type: String.t(),
          type: String.t(),
          sprite_id: String.t() | nil,
          work_item_id: String.t() | nil,
          run_id: String.t() | nil,
          timestamp: DateTime.t(),
          data: struct() | map()
        }

  @enforce_keys [:event_type, :timestamp, :data]
  defstruct [
    :event_type,
    :type,
    :sprite_id,
    :work_item_id,
    :run_id,
    :timestamp,
    :data,
    protocol_version: "v1"
  ]

  @doc "Create a new Event. Accepts either v1 field names or legacy names."
  def new(event_type, data, opts \\ []) do
    %__MODULE__{
      protocol_version: Keyword.get(opts, :protocol_version, "v1"),
      event_type: event_type,
      type: event_type,
      sprite_id: Keyword.get(opts, :sprite_id),
      work_item_id: Keyword.get(opts, :work_item_id) || Keyword.get(opts, :run_id),
      run_id: Keyword.get(opts, :run_id) || Keyword.get(opts, :work_item_id),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      data: data
    }
  end
end
