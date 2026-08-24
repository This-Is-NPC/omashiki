defmodule OmashikiWeb.Plugs.BearerAuthTest do
  use OmashikiWeb.ConnCase, async: false

  alias OmashikiWeb.Plugs.BearerAuth

  describe "missing credential" do
    @tag :unauthenticated
    test "returns 401 with a JSON body when no header / query / session is present",
         %{conn: conn} do
      conn = BearerAuth.call(conn, BearerAuth.init([]))
      assert conn.status == 401
      assert conn.halted
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "missing_token"
    end
  end

  describe "wrong bearer" do
    @tag :unauthenticated
    test "returns 403 when the supplied bearer does not match any active token",
         %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer not-the-right-one")
        |> BearerAuth.call(BearerAuth.init([]))

      assert conn.status == 403
      assert conn.halted
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_token"
    end
  end

  describe "valid bearer" do
    test "passes through and assigns :current_user, :current_token, :authenticated",
         %{conn: conn, user: user, token: token} do
      conn = BearerAuth.call(conn, BearerAuth.init([]))

      refute conn.halted
      assert conn.assigns[:authenticated] == true
      assert conn.assigns[:current_user].id == user.id
      assert conn.assigns[:current_token].id == token.id
    end

    test "accepts lowercase 'bearer'", %{user: user, token_plaintext: plaintext} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "bearer " <> plaintext)
        |> BearerAuth.call(BearerAuth.init([]))

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
    end

    test "accepts the bearer via ?token= query string", %{token_plaintext: plaintext} do
      conn =
        Phoenix.ConnTest.build_conn(:get, "/anything?token=" <> plaintext, nil)
        |> Plug.Conn.fetch_query_params()
        |> BearerAuth.call(BearerAuth.init([]))

      refute conn.halted
      assert conn.assigns[:authenticated] == true
    end

    test "rejects a revoked token", %{user: user} do
      {token, plaintext} = Omashiki.Fixtures.api_token_fixture(user)
      {:ok, _} = Omashiki.ApiTokens.revoke(user, token.id)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> plaintext)
        |> BearerAuth.call(BearerAuth.init([]))

      assert conn.status == 403
      assert conn.halted
    end
  end

  describe "session fallback" do
    @tag :unauthenticated
    test "valid user_id in session authenticates as that user", %{conn: conn} do
      user = Omashiki.Fixtures.user_fixture()

      conn =
        conn
        |> Plug.Test.init_test_session(%{"user_id" => user.id})
        |> BearerAuth.call(BearerAuth.init([]))

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
      assert is_nil(conn.assigns[:current_token])
    end
  end

  describe "auth_mode :none" do
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

    @tag :unauthenticated
    test "loopback without credential uses sole operator", %{conn: conn} do
      user = Omashiki.Fixtures.user_fixture()

      conn =
        %{conn | remote_ip: {127, 0, 0, 1}}
        |> BearerAuth.call(BearerAuth.init([]))

      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
      assert conn.assigns[:auth_mode_none] == true
      assert is_nil(conn.assigns[:current_token])
    end

    @tag :unauthenticated
    test "non-loopback without credential is rejected", %{conn: conn} do
      _ = Omashiki.Fixtures.user_fixture()

      conn =
        %{conn | remote_ip: {192, 168, 1, 50}}
        |> BearerAuth.call(BearerAuth.init([]))

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "auth_mode_none_loopback_only"
    end

    test "bearer still works under :none", %{conn: conn, user: user} do
      conn = BearerAuth.call(conn, BearerAuth.init([]))
      refute conn.halted
      assert conn.assigns[:current_user].id == user.id
      assert conn.assigns[:current_token]
    end
  end

  describe "REST integration via the router" do
    @tag :unauthenticated
    test "GET /api/v1/jobs without a token returns 401" do
      conn = Phoenix.ConnTest.build_conn() |> Phoenix.ConnTest.get("/api/v1/jobs")
      assert conn.status == 401
    end

    @tag :unauthenticated
    test "GET /api/v1/jobs with a wrong token returns 403" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer nope")
        |> Phoenix.ConnTest.get("/api/v1/jobs")

      assert conn.status == 403
    end

    test "GET /api/v1/jobs with the right token returns 200", %{conn: conn} do
      response = Phoenix.ConnTest.get(conn, "/api/v1/jobs")
      assert response.status == 200
    end

    @tag :unauthenticated
    test "GET /api/v1/health remains unauthenticated" do
      conn = Phoenix.ConnTest.build_conn() |> Phoenix.ConnTest.get("/api/v1/health")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    end

    @tag :unauthenticated
    test "public MCP is not mounted" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.post("/api/v1/mcp", Jason.encode!(%{"jsonrpc" => "2.0"}))

      assert conn.status == 404
    end
  end
end
