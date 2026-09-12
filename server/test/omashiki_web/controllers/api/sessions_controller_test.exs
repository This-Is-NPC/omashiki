defmodule OmashikiWeb.Api.SessionsControllerTest do
  use OmashikiWeb.ConnCase, async: false

  @moduletag :api

  setup do
    OmashikiWeb.RateLimiter.reset!()
    :ok
  end

  describe "POST /api/v1/sessions/issue_token" do
    @tag :unauthenticated
    test "returns 401 invalid_credentials on a bad password", %{conn: conn} do
      _ = user_fixture(%{username: "bob", password: "right-password-1"})

      response =
        post(
          conn,
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{
            "username" => "bob",
            "password" => "wrong"
          })
        )

      assert response.status == 401
      assert Jason.decode!(response.resp_body)["code"] == "invalid_credentials"
    end

    @tag :unauthenticated
    test "returns a fresh plaintext token on valid credentials", %{conn: conn} do
      _ = user_fixture(%{username: "bob", password: "right-password-1"})

      response =
        post(
          conn,
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{
            "username" => "bob",
            "password" => "right-password-1",
            "name" => "CLI on test"
          })
        )

      assert response.status == 200
      payload = Jason.decode!(response.resp_body)
      assert is_binary(payload["data"]["token"])
      assert payload["data"]["name"] == "CLI on test"
    end

    test "authenticated rotate requires submit and returns a token", %{conn: conn} do
      response = post(conn, ~p"/api/v1/sessions/rotate_token", %{})
      assert response.status == 200
      payload = Jason.decode!(response.resp_body)
      assert is_binary(payload["data"]["token"])
      assert_schema(payload, "TokenResponse", OmashikiWeb.ApiSpec.spec())
    end

    @tag :unauthenticated
    test "a read-only token cannot rotate" do
      user = user_fixture(%{username: "reader", password: "right-password-1"})

      {_token, plaintext} =
        api_token_fixture(user, %{
          scopes: ["read"],
          allowed_environments: ["*"],
          max_active_jobs: 10,
          ttl_days: 7
        })

      conn = json_conn() |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}")
      response = post(conn, ~p"/api/v1/sessions/rotate_token", %{})
      assert response.status == 403
      assert Jason.decode!(response.resp_body)["code"] == "insufficient_scope"
    end

    @tag :unauthenticated
    test "rate-limits after the configured budget", %{conn: conn} do
      _ = user_fixture(%{username: "bob", password: "right-password-1"})

      for _ <- 1..10 do
        post(
          conn,
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{
            "username" => "bob",
            "password" => "wrong"
          })
        )
      end

      response =
        post(
          conn,
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{
            "username" => "bob",
            "password" => "wrong"
          })
        )

      assert response.status == 429
      assert Jason.decode!(response.resp_body)["code"] == "rate_limited"
    end

    @tag :unauthenticated
    test "issue_token budget is per client address, not username", %{conn: conn} do
      _ = user_fixture(%{username: "bob", password: "right-password-1"})
      _ = user_fixture(%{username: "ann", password: "right-password-2"})

      for _ <- 1..10 do
        post(
          conn,
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "bob", "password" => "wrong"})
        )
      end

      response =
        post(
          conn,
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "ann", "password" => "wrong"})
        )

      assert response.status == 429
      assert Jason.decode!(response.resp_body)["code"] == "rate_limited"
    end
  end
end
