defmodule OmashikiWeb.ConfigLiveTest do
  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders repository, environment, runtime, and host declarations read-only", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/config")

    assert html =~ "Runtime configuration"
    assert html =~ "Host limits"
    assert html =~ "Repositories"
    assert html =~ "Environments"
    assert html =~ "Read-only"
    assert html =~ "restart to change"
    # Against the operator's own reading of the screen, not the raw document:
    # the CSRF and LiveView session tokens are base64url and will contain
    # short letter runs like these by chance.
    text = visible_text(html)
    refute text =~ "Save"
    refute text =~ "Edit"
    refute text =~ "Persona"
  end

  test "cache purge action is available only for configured groups", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/config")
    html = render_click(view, "purge_cache", %{"group" => "not-configured"})
    assert html =~ "requires a configured group"
  end
end
