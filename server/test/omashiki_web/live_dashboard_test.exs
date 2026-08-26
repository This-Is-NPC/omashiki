defmodule OmashikiWeb.LiveDashboardTest do
  @moduledoc """
  `:phoenix_live_dashboard` has been a declared dependency, and its
  `RequestLogger` plug has been in the endpoint, since the first commit — but it
  was never routed, so the one tool that could have answered "what are these 65
  processes actually doing" was paid for and unreachable.

  It is routed behind the operator hook now. These tests pin who gets in.
  """

  use OmashikiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Omashiki.Accounts

  describe "with login enabled" do
    test "an operator reaches the dashboard", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/dashboard/home")

      assert visible_text(html) =~ "Run queues"
    end

    @tag :unauthenticated
    test "an anonymous visitor does not", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{})

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/dashboard/home")
    end
  end

  # `[auth] enabled = false` is a supported local configuration, and the console
  # honours it: no login screen, act as the local owner. The dashboard is the one
  # surface where that is not enough, because it exposes process state, message
  # queues and stacktraces rather than queue data. `BearerAuth` already resolves
  # exactly this tension for the API by trusting `:none` only from a loopback
  # peer; this is that same rule on the one browser route that needs it.
  describe "with login disabled" do
    setup do
      previous = Application.get_env(:omashiki, :auth_mode)
      Application.put_env(:omashiki, :auth_mode, :none)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:omashiki, :auth_mode)
        else
          Application.put_env(:omashiki, :auth_mode, previous)
        end
      end)

      :ok
    end

    test "a loopback peer reaches the dashboard with no logged-in user", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{})
      assert %Accounts.User{} = Accounts.local_owner()

      {:ok, _lv, html} = live(peer(conn, {127, 0, 0, 1}), "/dashboard/home")

      assert visible_text(html) =~ "Run queues"
    end

    test "a peer on the LAN does not", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{})
      assert %Accounts.User{} = Accounts.local_owner()

      assert {:error, {:redirect, %{to: to}}} =
               live(peer(conn, {192, 168, 1, 50}), "/dashboard/home")

      assert to == "/"
    end

    # The rest of the console stays exactly as reachable as it was: this is a
    # narrowing of one route, not a change to what `auth.enabled = false` means.
    test "the operator screens are untouched by the dashboard's extra gate", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{})
      assert %Accounts.User{} = Accounts.local_owner()

      {:ok, _lv, html} = live(peer(conn, {192, 168, 1, 50}), ~p"/")

      assert visible_text(html) =~ "Operations overview"
    end
  end

  defp peer(conn, address) do
    Plug.Test.put_peer_data(conn, %{address: address, port: 44_444, ssl_cert: nil})
  end
end
