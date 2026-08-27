defmodule OmashikiWeb.PageControllerTest do
  use OmashikiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET / mounts Home", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Home"
    assert html =~ "Operations overview"
  end
end
