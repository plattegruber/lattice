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

  pipeline :authenticated_api do
    plug :accepts, ["json"]
    plug LatticeWeb.Plugs.Auth
  end

  scope "/", LatticeWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Unauthenticated API routes
  scope "/", LatticeWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Authenticated API routes -- protected by bearer token
  scope "/api", LatticeWeb do
    pipe_through :authenticated_api

    # Future API endpoints go here
  end

  # Authenticated LiveView routes
  live_session :authenticated,
    on_mount: [{LatticeWeb.Hooks.AuthHook, :default}] do
    scope "/", LatticeWeb do
      pipe_through :browser

      # Future LiveView routes go here
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:lattice, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LatticeWeb.Telemetry
    end
  end
end
