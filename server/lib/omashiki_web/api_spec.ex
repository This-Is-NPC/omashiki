defmodule OmashikiWeb.ApiSpec do
  @moduledoc "Generated OpenAPI 3.0 document for `/api/v1`."

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, OAuthFlow, OAuthFlows}

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
            type: :oauth2,
            description: "API token presented as HTTP Bearer",
            flows: %OAuthFlows{
              clientCredentials: %OAuthFlow{
                tokenUrl: "/api/v1/sessions/issue_token",
                scopes: %{
                  "read" => "Read jobs, discovery, fleet, events, and results",
                  "submit" => "Admit, retry, and redeliver jobs",
                  "cancel" => "Cancel jobs"
                }
              }
            }
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
