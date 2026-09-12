defmodule OmashikiWeb.ApiSpec do
  @moduledoc """
  Generated OpenAPI 3.0 document for `/api/v1`.

  `open_api_spex ~> 3.21` emits OpenAPI 3.0. Keep `openapi: "3.0.3"` so the
  served document and the library dialect stay the same; do not bump to 3.1.

  Action-specific error statuses are declared on each `operation()`. This
  module only adds statuses that every matching pipeline can produce: bearer
  plugs (401/403/429) and OpenApiSpex cast failures (422) when the operation
  has a body or parameters.
  """

  alias OpenApiSpex.{
    Components,
    Info,
    MediaType,
    OpenApi,
    Operation,
    Paths,
    Response,
    SecurityScheme
  }

  alias OmashikiWeb.ApiSpec.Schemas

  @behaviour OpenApi

  @pipeline_problem_statuses [401, 403, 429]
  @cast_problem_status 422

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
    |> put_pipeline_responses()
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp put_pipeline_responses(%OpenApi{paths: paths} = spec) do
    %{spec | paths: Map.new(paths, fn {path, item} -> {path, merge_path_item(item)} end)}
  end

  defp merge_path_item(item) do
    Enum.reduce([:get, :post, :put, :patch, :delete], item, fn method, acc ->
      case Map.get(acc, method) do
        %Operation{} = operation ->
          Map.put(acc, method, put_pipeline_errors(operation))

        _ ->
          acc
      end
    end)
  end

  defp put_pipeline_errors(%Operation{} = operation) do
    statuses =
      []
      |> maybe_put_statuses(bearer?(operation), @pipeline_problem_statuses)
      |> maybe_put_statuses(castable?(operation), [@cast_problem_status])
      |> Enum.uniq()

    responses = Enum.reduce(statuses, operation.responses || %{}, &put_problem_response/2)
    %{operation | responses: responses}
  end

  defp maybe_put_statuses(statuses, true, extra), do: extra ++ statuses
  defp maybe_put_statuses(statuses, false, _extra), do: statuses

  defp castable?(%Operation{requestBody: body, parameters: params}) do
    not is_nil(body) or params not in [nil, []]
  end

  defp put_problem_response(status, responses) do
    Map.put_new(responses, status, %Response{
      description: "Error",
      content: %{
        "application/problem+json" => %MediaType{schema: Schemas.Problem}
      }
    })
  end

  defp bearer?(%Operation{security: security}) when is_list(security) do
    Enum.any?(security, fn
      %{"bearer" => _} -> true
      %{bearer: _} -> true
      _ -> false
    end)
  end

  defp bearer?(_), do: false
end
