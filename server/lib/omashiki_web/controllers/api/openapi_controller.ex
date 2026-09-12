defmodule OmashikiWeb.Api.OpenApiController do
  use OmashikiWeb.Api.Controller

  alias OmashikiWeb.ApiSpec
  alias OmashikiWeb.ApiSpec.Schemas

  tags(["meta"])

  operation(:show,
    summary: "OpenAPI document",
    security: [],
    responses: %{200 => {"OpenAPI", "application/json", Schemas.OpenApiDocument}}
  )

  def show(conn, _params) do
    json(conn, ApiSpec.spec())
  end
end
