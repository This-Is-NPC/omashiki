defmodule OmashikiWeb.ApiSpec do
  @moduledoc """
  Generated OpenAPI 3.0 document for `/api/v1`.

  `open_api_spex ~> 3.21` emits OpenAPI 3.0. Keep `openapi: "3.0.3"` so the
  served document and the library dialect stay the same; do not bump to 3.1.
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      openapi: "3.0.3",
      info: %Info{
        title: "Omashiki",
        version: "1.0.0",
        description: "Public HTTP API for Omashiki job admission and observation."
      },
      paths: Paths.from_router(OmashikiWeb.Router),
      components: %Components{
        securitySchemes: %{
          "bearer" => %SecurityScheme{
            type: :http,
            scheme: "bearer",
            bearerFormat: "opaque",
            description: "API token presented as HTTP Bearer"
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
