defmodule OmashikiWeb.Api.HealthControllerTest do
  use OmashikiWeb.ConnCase, async: false

  @moduletag :api

  describe "GET /api/v1/health" do
    test "returns ok status", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")
      assert json_response(conn, 200)["status"] == "ok"
      assert_schema(json_response(conn, 200), "Health", OmashikiWeb.ApiSpec.spec())
    end
  end
end
