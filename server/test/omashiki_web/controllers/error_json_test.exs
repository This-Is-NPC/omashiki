defmodule OmashikiWeb.ErrorJSONTest do
  use OmashikiWeb.ConnCase, async: false

  test "renders 404" do
    assert OmashikiWeb.ErrorJSON.render("404.json", %{}) == %{
             type: "about:blank",
             title: "Resource not found",
             status: 404,
             code: "not_found",
             detail: "Resource not found",
             errors: [],
             request_id: nil
           }
  end

  test "renders 500" do
    assert OmashikiWeb.ErrorJSON.render("500.json", %{}) == %{
             type: "about:blank",
             title: "Internal Server Error",
             status: 500,
             code: "internal_error",
             detail: "Internal Server Error",
             errors: [],
             request_id: nil
           }
  end

  test "undeclared ErrorJSON status raises against the served operation" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:method, "GET")
      |> Map.put(:path_info, ["api", "v1", "jobs"])
      |> Plug.Conn.put_private(:phoenix_router, OmashikiWeb.Router)
      |> OpenApiSpex.Plug.PutApiSpec.call(OmashikiWeb.ApiSpec)

    assert_raise ArgumentError, ~r/undeclared problem status 400/, fn ->
      OmashikiWeb.ErrorJSON.render("400.json", %{conn: conn})
    end
  end
end
