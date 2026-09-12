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

  test "served spec includes pipeline statuses and operation-declared errors" do
    spec = OmashikiWeb.ApiSpec.spec() |> Jason.encode!() |> Jason.decode!()
    jobs = spec["paths"]["/api/v1/jobs"]
    refute Map.has_key?(jobs["get"]["responses"], "400")

    assert "401" in Map.keys(jobs["post"]["responses"])
    assert "429" in Map.keys(jobs["post"]["responses"])
    assert "429" in Map.keys(spec["paths"]["/api/v1/jobs/{id}/retry"]["post"]["responses"])
    assert "429" in Map.keys(spec["paths"]["/api/v1/jobs/{id}/result"]["get"]["responses"])
    assert "503" in Map.keys(jobs["post"]["responses"])
    assert "409" in Map.keys(spec["paths"]["/api/v1/jobs/batch"]["post"]["responses"])

    assert "404" in Map.keys(
             spec["paths"]["/api/v1/jobs/{id}/webhook-deliveries"]["get"]["responses"]
           )
  end

  test "pipeline plugs check the matched operation before the controller runs" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:method, "GET")
      |> Map.put(:path_info, ["api", "v1", "jobs"])
      |> Plug.Conn.put_private(:phoenix_router, OmashikiWeb.Router)
      |> OpenApiSpex.Plug.PutApiSpec.call(OmashikiWeb.ApiSpec)

    refute conn.private[:phoenix_controller]

    assert_raise ArgumentError, ~r/undeclared problem status 404/, fn ->
      Problem.send(conn, "not_found")
    end
  end

  test "encoded path segments still match the served operation" do
    spec_conn = fn path_info ->
      Phoenix.ConnTest.build_conn()
      |> Map.put(:method, "GET")
      |> Map.put(:path_info, path_info)
      |> Plug.Conn.put_private(:phoenix_router, Router)
      |> OpenApiSpex.Plug.PutApiSpec.call(OmashikiWeb.ApiSpec)
    end

    for path_info <- [
          ["api", "v1", "jobs", "abc%20def"],
          ["api", "v1", "jobs", "abc%2Fdef"]
        ] do
      conn = spec_conn.(path_info)
      refute conn.private[:phoenix_controller]

      assert_raise ArgumentError, ~r/undeclared problem status 400/, fn ->
        OmashikiWeb.ErrorJSON.render("400.json", %{conn: conn})
      end
    end
  end

  test "pipeline 401 and unmatched API 404 are Problem documents" do
    spec = OmashikiWeb.ApiSpec.spec()

    missing = Phoenix.ConnTest.build_conn() |> get("/api/v1/jobs")
    assert missing.status == 401
    assert json_response(missing, 401)["code"] == "missing_token"
    assert_schema(json_response(missing, 401), "Problem", spec)

    unknown =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> get("/api/v1/this-route-does-not-exist")

    assert unknown.status == 404
    body = json_response(unknown, 404)
    assert body["code"] == "not_found"
    assert_schema(body, "Problem", spec)
  end

  test "undeclared problem status raises against the served operation" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_private(:phoenix_controller, OmashikiWeb.Api.HealthController)
      |> Plug.Conn.put_private(:phoenix_action, :show)
      |> OpenApiSpex.Plug.PutApiSpec.call(OmashikiWeb.ApiSpec)

    assert_raise ArgumentError, ~r/undeclared problem status 404/, fn ->
      Problem.send(conn, "not_found")
    end
  end

  test "HTTP read timeout is an integer and does not replace the test bind" do
    http = Application.get_env(:omashiki, OmashikiWeb.Endpoint)[:http]
    timeout = Keyword.get(http[:thousand_island_options] || [], :read_timeout)
    assert is_integer(timeout)
    assert timeout > 0
    assert Keyword.get(http, :port) == 4002
  end

  test "OpenAPI document lints as a valid 3.0 document" do
    spec = OmashikiWeb.ApiSpec.spec() |> Jason.encode!() |> Jason.decode!()
    schemas = spec["components"]["schemas"] || %{}

    assert spec["openapi"] == "3.0.3"
    assert is_binary(spec["info"]["title"])
    assert is_binary(spec["info"]["version"])
    assert is_map(spec["paths"]) and map_size(spec["paths"]) > 0
    assert is_map(schemas) and map_size(schemas) > 0

    unresolved = unresolved_refs(spec, spec)
    assert unresolved == [], "unresolved $ref: #{inspect(unresolved)}"

    missing_ids =
      for {path, item} <- spec["paths"],
          {method, operation} <- item,
          method in ~w(get post put patch delete),
          is_map(operation),
          not is_binary(operation["operationId"]) do
        "#{method} #{path}"
      end

    assert missing_ids == [], "operations missing operationId: #{inspect(missing_ids)}"

    duplicate_ids =
      spec["paths"]
      |> Enum.flat_map(fn {_path, item} ->
        for {method, operation} <- item,
            method in ~w(get post put patch delete),
            is_map(operation),
            id = operation["operationId"],
            is_binary(id),
            do: id
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, n} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))

    assert duplicate_ids == [], "duplicate operationId: #{inspect(duplicate_ids)}"

    missing_path_params =
      for {path, item} <- spec["paths"],
          {method, operation} <- item,
          method in ~w(get post put patch delete),
          is_map(operation),
          name <- Regex.scan(~r/\{([^}]+)\}/, path) |> Enum.map(&List.last/1),
          name not in path_param_names(operation, spec) do
        "#{method} #{path} {#{name}}"
      end

    assert missing_path_params == [],
           "path params not declared: #{inspect(missing_path_params)}"

    missing_descriptions =
      for {path, item} <- spec["paths"],
          {method, operation} <- item,
          method in ~w(get post put patch delete),
          is_map(operation),
          {status, response} <- operation["responses"] || %{},
          not is_binary(response["description"]) do
        "#{method} #{path} #{status}"
      end

    assert missing_descriptions == [],
           "responses missing description: #{inspect(missing_descriptions)}"

    problems =
      for {path, item} <- spec["paths"],
          {method, operation} <- item,
          method in ~w(get post put patch delete),
          is_map(operation),
          {status, response} <- operation["responses"] || %{},
          match?({n, ""} when n >= 400, Integer.parse(status)),
          not problem_response?(response) do
        "#{method} #{path} #{status}"
      end

    assert problems == [], "error responses missing Problem schema: #{inspect(problems)}"
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

  defp problem_response?(%{"content" => content}) when is_map(content) do
    Enum.any?(content, fn {type, media} ->
      String.contains?(to_string(type), "problem") or
        get_in(media, ["schema", "$ref"]) == "#/components/schemas/Problem"
    end)
  end

  defp problem_response?(_), do: false

  defp unresolved_refs(node, spec) when is_map(node) do
    case Map.get(node, "$ref") do
      ref when is_binary(ref) ->
        if lookup_ref(spec, ref), do: [], else: [ref]

      _ ->
        Enum.flat_map(node, fn {_k, v} -> unresolved_refs(v, spec) end)
    end
  end

  defp unresolved_refs(node, spec) when is_list(node) do
    Enum.flat_map(node, &unresolved_refs(&1, spec))
  end

  defp unresolved_refs(_, _), do: []

  defp lookup_ref(spec, "#/" <> path) do
    get_in(spec, String.split(path, "/"))
  end

  defp lookup_ref(_, _), do: nil

  defp path_param_names(operation, spec) do
    for param <- operation["parameters"] || [],
        resolved = resolve_node(param, spec),
        resolved["in"] == "path",
        is_binary(resolved["name"]) do
      resolved["name"]
    end
  end

  defp resolve_node(%{"$ref" => ref}, spec) do
    lookup_ref(spec, ref) || %{}
  end

  defp resolve_node(node, _spec), do: node
end
