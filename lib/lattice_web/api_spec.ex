defmodule LatticeWeb.ApiSpec do
  @moduledoc """
  OpenAPI 3.0 specification for the Lattice REST API.

  Aggregates operation specs from all API controllers and serves as the
  single source of truth for the machine-readable API contract.
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Lattice API",
        version: "0.1.0",
        description: """
        REST API for the Lattice control plane. Provides endpoints for managing
        Sprites (AI coding agents), fleet operations, and intent lifecycle workflows.
        """
      },
      servers: [
        %Server{url: "/", description: "Current server"}
      ],
      paths: Paths.from_router(LatticeWeb.Router),
      components: %Components{
        securitySchemes: %{
          "BearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description:
              "Bearer token authentication. Pass your API token in the Authorization header."
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
