defmodule LatticeWeb.HealthController do
  use LatticeWeb, :controller

  alias Lattice.Instance

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      timestamp: DateTime.utc_now(),
      instance: Instance.identity()
    })
  end
end
