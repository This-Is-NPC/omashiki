defmodule OmashikiWeb.ScreenSkeletonTest do
  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "operator routes expose only queue operations", %{conn: conn} do
    {:ok, _lv, overview} = live(conn, ~p"/")
    {:ok, _lv, queue} = live(conn, ~p"/queue")
    {:ok, _lv, config} = live(conn, ~p"/config")

    assert overview =~ "Operations overview"
    assert overview =~ "Cache health"
    assert overview =~ "Webhook failures"
    assert queue =~ "Blocked"
    assert queue =~ "Queued"
    assert queue =~ "Running"
    assert config =~ "Repositories"
    assert config =~ "Environments"
    assert config =~ "Caches"

    for html <- [overview, queue, config] do
      refute html =~ "DAG"
      refute html =~ "Review"
      refute html =~ "Persona"
      refute html =~ "Comment"
      refute html =~ "Drag"
      refute html =~ "Workflow"
    end
  end

  test "browser routes require an authenticated operator", %{} do
    conn = build_conn() |> Plug.Test.init_test_session(%{})
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/queue")
  end

  test "primary navigation contains only operational routes", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/queue")
    assert html =~ ~s(href="/config")
    refute html =~ ~s(href="/tasks")
  end
end
