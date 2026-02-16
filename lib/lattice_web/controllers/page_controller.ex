defmodule LatticeWeb.PageController do
  use LatticeWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/sprites")
  end
end
