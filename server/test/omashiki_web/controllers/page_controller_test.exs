defmodule OmashikiWeb.PageControllerTest do
  use OmashikiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET / mounts Home with the task views", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Home"
    assert html =~ "Built-in views"
  end

  test "GET /system mounts the system health overview", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/system")
    assert html =~ "System"
    assert html =~ "Operations overview"
  end
end
