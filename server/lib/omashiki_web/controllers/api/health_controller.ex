defmodule OmashikiWeb.Api.HealthController do
  use OmashikiWeb.Api.Controller

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
