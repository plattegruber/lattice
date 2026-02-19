defmodule LatticeWeb.Api.SearchController do
  @moduledoc """
  Search API controller — searches across intents, sprites, and runs.
  """

  use LatticeWeb, :controller

  alias Lattice.Intents.Store
  alias Lattice.Sprites.FleetManager

  @doc "GET /api/search?q=<query> — search across entities."
  def index(conn, %{"q" => query}) when byte_size(query) >= 1 do
    query_lower = String.downcase(query)

    results = %{
      intents: search_intents(query, query_lower),
      sprites: search_sprites(query_lower)
    }

    json(conn, %{data: results, query: query, timestamp: DateTime.utc_now()})
  end

  def index(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Query parameter 'q' is required", code: "MISSING_QUERY"})
  end

  defp search_intents(query, query_lower) do
    {:ok, intents} = Store.list()

    intents
    |> Enum.filter(fn i ->
      String.contains?(String.downcase(i.summary || ""), query_lower) or
        String.contains?(i.id, query) or
        String.contains?(String.downcase(to_string(i.kind)), query_lower)
    end)
    |> Enum.take(20)
    |> Enum.map(fn i ->
      %{
        id: i.id,
        kind: i.kind,
        state: i.state,
        summary: i.summary,
        updated_at: i.updated_at
      }
    end)
  end

  defp search_sprites(query_lower) do
    FleetManager.list_sprites()
    |> Enum.filter(fn s ->
      String.contains?(String.downcase(s.sprite_id), query_lower)
    end)
    |> Enum.take(20)
    |> Enum.map(fn s ->
      %{
        sprite_id: s.sprite_id,
        observed_state: s.observed_state,
        desired_state: s.desired_state
      }
    end)
  end
end
