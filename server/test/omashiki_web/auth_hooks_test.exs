defmodule OmashikiWeb.AuthHooksTest do
  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "require_user on_mount hook" do
    @tag :unauthenticated
    test "GET / without a session redirects to /login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    end

    @tag :unauthenticated
    test "GET / with a session referencing a missing user redirects to /login?reason=invalid",
         %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          "user_id" => "00000000-0000-0000-0000-000000000000"
        })

      assert {:error, {:redirect, %{to: "/login?reason=invalid"}}} = live(conn, ~p"/")
    end

    test "GET / with a logged-in user mounts the LiveView", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Home"
      assert html =~ "Operations overview"
    end
  end
end
