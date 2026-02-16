defmodule LatticeWeb.PageController do
  use LatticeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
