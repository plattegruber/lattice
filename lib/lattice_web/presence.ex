defmodule LatticeWeb.Presence do
  @moduledoc """
  Tracks which operators are viewing fleet-related pages.

  Used by `FleetManager` to adapt its reconciliation interval:
  fast polling when viewers are present, slow when nobody is watching.

  ## Usage

  Track a viewer in a LiveView mount:

      if connected?(socket) do
        LatticeWeb.Presence.track(self(), "fleet:viewers", socket.id, %{
          page: :fleet,
          joined_at: DateTime.utc_now()
        })
      end

  Check for active viewers:

      LatticeWeb.Presence.has_viewers?()

  Phoenix.Presence handles crash/disconnect cleanup automatically via
  process monitoring. Works across distributed nodes via CRDT sync.
  """

  use Phoenix.Presence,
    otp_app: :lattice,
    pubsub_server: Lattice.PubSub

  @viewers_topic "fleet:viewers"

  @doc "Returns the PubSub topic used for fleet viewer tracking."
  @spec viewers_topic() :: String.t()
  def viewers_topic, do: @viewers_topic

  @doc "Returns `true` if at least one operator has a fleet-related page open."
  @spec has_viewers?() :: boolean()
  def has_viewers? do
    @viewers_topic
    |> list()
    |> map_size()
    |> Kernel.>(0)
  end

  @doc "Returns the count of distinct viewer presences."
  @spec viewer_count() :: non_neg_integer()
  def viewer_count do
    @viewers_topic
    |> list()
    |> map_size()
  end
end
