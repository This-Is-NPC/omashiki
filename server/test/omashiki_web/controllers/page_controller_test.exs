defmodule OmashikiWeb.PageControllerTest do
  use OmashikiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET / mounts Overview", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Overview"
  end
end
