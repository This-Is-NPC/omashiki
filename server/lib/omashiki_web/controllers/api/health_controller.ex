defmodule OmashikiWeb.Api.HealthController do
  use OmashikiWeb.Api.Controller

  alias OmashikiWeb.ApiSpec.Schemas

  tags(["meta"])

  operation(:show,
    summary: "Service health",
    security: [],
    responses: %{200 => {"Health", "application/json", Schemas.Health}}
  )

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
