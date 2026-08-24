defmodule OmashikiWeb.Api.HealthController do
  use OmashikiWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
