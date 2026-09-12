defmodule OmashikiWeb.Api.ApiContractTest do
  use OmashikiWeb.ConnCase, async: false

  @moduletag :api

  alias OmashikiWeb.Api.Problem
  alias OmashikiWeb.ApiSpec.Schemas
  alias OmashikiWeb.Router

  @excluded [
    {"POST", "/api/v1/tools-proxy/:server"},
    {"POST", "/api/v1/gateway/v1/chat/completions"}
  ]

  test "every public /api/v1 route is declared in the OpenAPI spec" do
    spec = OmashikiWeb.ApiSpec.spec()
    paths = spec.paths || %{}

    missing =
      Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/v1"))
      |> Enum.reject(fn route ->
        {route.verb |> to_string() |> String.upcase(), route.path} in @excluded
      end)
      |> Enum.reject(fn route ->
        path = openapi_path(route.path)
        method = route.verb |> to_string() |> String.downcase() |> String.to_atom()

        case Map.get(paths, path) do
          %OpenApiSpex.PathItem{} = item -> Map.get(item, method) != nil
          _ -> false
        end
      end)
      |> Enum.map(&"#{String.upcase(to_string(&1.verb))} #{&1.path}")

    assert missing == [], "routes missing from OpenAPI: #{inspect(missing)}"
  end

  test "every problem code is in the Problem schema enum" do
    enum = Schemas.Problem.schema().properties.code.enum
    assert Enum.sort(Problem.codes()) == Enum.sort(enum)
  end

  test "document is OpenAPI 3.0.3" do
    spec = OmashikiWeb.ApiSpec.spec()
    assert spec.openapi == "3.0.3"
  end

  test "job writes declare 503 busy and GET /jobs declares 422" do
    spec = OmashikiWeb.ApiSpec.spec() |> Jason.encode!() |> Jason.decode!()
    jobs = spec["paths"]["/api/v1/jobs"]
    assert Map.has_key?(jobs["get"]["responses"], "422")
    refute Map.has_key?(jobs["get"]["responses"], "400")
    assert Map.has_key?(jobs["post"]["responses"], "503")
    assert Map.has_key?(jobs["post"]["responses"], "422")
    assert Map.has_key?(spec["paths"]["/api/v1/jobs"]["post"]["responses"], "503")
    assert Map.has_key?(spec["paths"]["/api/v1/jobs/batch"]["post"]["responses"], "503")
    assert Map.has_key?(spec["paths"]["/api/v1/jobs/{id}/retry"]["post"]["responses"], "503")
    assert Map.has_key?(spec["paths"]["/api/v1/jobs/{id}/cancel"]["post"]["responses"], "503")
  end

  test "GET /api/v1/openapi.json matches ApiSpec.spec/0" do
    conn = Phoenix.ConnTest.build_conn() |> get("/api/v1/openapi.json")
    assert conn.status == 200
    decoded = Jason.decode!(conn.resp_body)
    spec = OmashikiWeb.ApiSpec.spec() |> Jason.encode!() |> Jason.decode!()
    assert decoded == spec
  end

  test "bearer security is HTTP Bearer, not OAuth" do
    spec = OmashikiWeb.ApiSpec.spec() |> Jason.encode!() |> Jason.decode!()
    bearer = spec["components"]["securitySchemes"]["bearer"]
    assert bearer["type"] == "http"
    assert bearer["scheme"] == "bearer"
    refute Map.has_key?(bearer, "flows")
  end

  test "every operation declares responses" do
    spec = OmashikiWeb.ApiSpec.spec()

    missing =
      for {path, item} <- spec.paths,
          method <- [:get, :post, :put, :patch, :delete],
          operation = Map.get(item, method),
          is_map(operation),
          operation.responses in [nil, %{}] do
        "#{method} #{path}"
      end

    assert missing == []
  end

  test "GET /api/v1/agent-skill fills the installation URL" do
    conn = Phoenix.ConnTest.build_conn() |> get("/api/v1/agent-skill")
    assert conn.status == 200
    assert conn.resp_body =~ "/api/v1/openapi.json"
    refute conn.resp_body =~ "{{OMASHIKI_URL}}"

    assert conn.resp_body =~ "http://www.example.com/api/v1/openapi.json" or
             conn.resp_body =~ "http://localhost"
  end

  defp openapi_path(path) do
    path
    |> String.replace(~r/:([A-Za-z_]+)/, "{\\1}")
  end
end
