defmodule OmashikiWeb.ScreenSkeletonTest do
  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "operator routes expose only Home and Config", %{conn: conn} do
    {:ok, _lv, overview} = live(conn, ~p"/")
    {:ok, _lv, config} = live(conn, ~p"/config")

    assert overview =~ "Operations overview"
    assert overview =~ "Cache health"
    assert overview =~ "Webhook failures"
    assert config =~ "Repositories"
    assert config =~ "Environments"
    assert config =~ "Caches"
    assert config =~ "Reload configuration"

    for html <- [overview, config] do
      text = visible_text(html)
      refute text =~ "DAG"
      refute text =~ "Review"
      refute text =~ "Persona"
      refute text =~ "Comment"
      refute text =~ "Drag"
      refute text =~ "Workflow"
    end
  end

  test "browser routes require an authenticated operator", %{} do
    conn = build_conn() |> Plug.Test.init_test_session(%{})
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/config")
  end

  test "primary navigation contains only Home and Config", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")

    nav =
      html
      |> Floki.parse_document!()
      |> Floki.find("nav[aria-label=\"Primary\"]")

    assert Floki.attribute(nav, "a", "href") == ["/", "/config"]
    refute html =~ ~s(href="/queue")
    refute html =~ ~s(href="/runtime")
    refute html =~ ~s(href="/tasks")
  end
end
