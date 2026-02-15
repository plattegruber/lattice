defmodule LatticeWeb.HealthController do
  use LatticeWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
