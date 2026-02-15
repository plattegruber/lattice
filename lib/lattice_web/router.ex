defmodule LatticeWeb.Router do
  use LatticeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LatticeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", LatticeWeb do
    pipe_through :browser

    live "/", FleetLive, :index
  end

  scope "/api", LatticeWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:lattice, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LatticeWeb.Telemetry
    end
  end
end
