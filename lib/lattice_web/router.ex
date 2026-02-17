defmodule LatticeWeb.Router do
  @moduledoc """
  Router for the Lattice web application.

  Defines three pipelines:

  - `:browser` -- HTML requests with session, CSRF protection, and LiveView flash
  - `:api` -- JSON requests (unauthenticated, used for health checks)
  - `:authenticated_api` -- JSON requests protected by bearer token via `LatticeWeb.Plugs.Auth`

  LiveView routes are wrapped in an authenticated `live_session` using
  `LatticeWeb.Hooks.AuthHook`.
  """
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

  pipeline :api_docs do
    plug :accepts, ["json", "html"]
    plug OpenApiSpex.Plug.PutApiSpec, module: LatticeWeb.ApiSpec
  end

  scope "/", LatticeWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Sprite detail route
  scope "/", LatticeWeb do
    pipe_through :browser

    live "/sprites/:id", SpriteLive.Show
  end

  # OpenAPI spec and Swagger UI (unauthenticated)
  scope "/api" do
    pipe_through :api_docs

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
  end

  # Unauthenticated API routes
  scope "/", LatticeWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Authenticated API routes -- protected by bearer token
  scope "/api", LatticeWeb.Api do
    pipe_through :authenticated_api

    get "/fleet", FleetController, :index
    post "/fleet/audit", FleetController, :audit

    get "/sprites", SpriteController, :index
    post "/sprites", SpriteController, :create
    get "/sprites/:id", SpriteController, :show
    put "/sprites/:id/desired", SpriteController, :update_desired
    post "/sprites/:id/reconcile", SpriteController, :reconcile

    get "/intents", IntentController, :index
    get "/intents/:id", IntentController, :show
    post "/intents", IntentController, :create
    post "/intents/:id/approve", IntentController, :approve
    post "/intents/:id/reject", IntentController, :reject
    post "/intents/:id/cancel", IntentController, :cancel
  end

  # Authenticated LiveView routes
  live_session :authenticated,
    on_mount: [{LatticeWeb.Hooks.AuthHook, :default}] do
    scope "/", LatticeWeb do
      pipe_through :browser

      live "/sprites", FleetLive
      live "/approvals", ApprovalsLive
      live "/incidents", IncidentsLive
      live "/intents", IntentsLive
      live "/intents/:id", IntentLive.Show
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
