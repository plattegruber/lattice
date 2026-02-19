defmodule LatticeWeb.Plugs.CacheBodyReader do
  @moduledoc """
  A custom body reader that caches the raw request body in `conn.assigns`.

  Used for webhook signature verification, where we need the exact raw bytes
  that were signed by the sender to compute HMAC-SHA256.

  ## Usage

  Configure in the endpoint's `Plug.Parsers`:

      plug Plug.Parsers,
        body_reader: {LatticeWeb.Plugs.CacheBodyReader, :read_body, []},
        ...

  The raw body is stored in `conn.assigns[:raw_body]` as an iodata list.
  """

  @doc """
  Read the request body and cache it in conn assigns.

  Implements the `body_reader` callback signature expected by `Plug.Parsers`.
  """
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
        {:ok, body, conn}

      {:more, body, conn} ->
        conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
