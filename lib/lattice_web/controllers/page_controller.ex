defmodule LatticeWeb.PageController do
  @moduledoc """
  Landing page controller that redirects based on auth state.
  """
  use LatticeWeb, :controller

  def home(conn, _params) do
    if get_session(conn, "auth_token") do
      redirect(conn, to: ~p"/sprites")
    else
      redirect(conn, to: ~p"/login")
    end
  end
end
