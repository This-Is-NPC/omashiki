defmodule OmashikiWeb.ApiSpec do
  @moduledoc """
  Generated OpenAPI 3.0 document for `/api/v1`.

  `open_api_spex ~> 3.21` emits OpenAPI 3.0. Keep `openapi: "3.0.3"` so the
  served document and the library dialect stay the same; do not bump to 3.1.
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

  alias OmashikiWeb.Api.ErrorSurface
  alias OmashikiWeb.ApiSpec.Schemas

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
    |> put_error_responses()
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp put_error_responses(%OpenApi{paths: paths} = spec) do
    %{spec | paths: Map.new(paths, fn {path, item} -> {path, merge_path_item(path, item)} end)}
  end

  defp merge_path_item(path, item) do
    Enum.reduce([:get, :post, :put, :patch, :delete], item, fn method, acc ->
      case Map.get(acc, method) do
        %Operation{} = operation ->
          Map.put(acc, method, put_operation_errors(path, method, operation))

        _ ->
          acc
      end
    end)
  end

  defp put_operation_errors(path, method, %Operation{} = operation) do
    statuses = ErrorSurface.required_statuses(path, Atom.to_string(method), bearer?(operation))
    responses = Enum.reduce(statuses, operation.responses || %{}, &put_problem_response/2)
    %{operation | responses: responses}
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
