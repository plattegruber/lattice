defmodule LatticeWeb.PageController do
  @moduledoc """
  Landing page controller that redirects to the fleet dashboard.
  """
  use LatticeWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/sprites")
  end
end
