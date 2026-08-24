defmodule OmashikiWeb.Api.SessionsControllerTest do
  use OmashikiWeb.ConnCase, async: false

  setup do
    OmashikiWeb.RateLimiter.reset!()
    :ok
  end

  describe "POST /api/v1/sessions/issue_token" do
    @tag :unauthenticated
    test "returns 401 invalid_credentials on a bad password", %{conn: conn} do
      _ = user_fixture(%{username: "bob", password: "right-password-1"})

      response =
        post(conn, ~p"/api/v1/sessions/issue_token", %{
          "username" => "bob",
          "password" => "wrong"
        })

      assert response.status == 401
      assert Jason.decode!(response.resp_body)["error"] == "invalid_credentials"
    end

    @tag :unauthenticated
    test "returns a fresh plaintext token on valid credentials", %{conn: conn} do
      _ = user_fixture(%{username: "bob", password: "right-password-1"})

      response =
        post(conn, ~p"/api/v1/sessions/issue_token", %{
          "username" => "bob",
          "password" => "right-password-1",
          "name" => "CLI on test"
        })

      assert response.status == 200
      payload = Jason.decode!(response.resp_body)
      assert is_binary(payload["data"]["token"])
      assert payload["data"]["name"] == "CLI on test"
    end

    @tag :unauthenticated
    test "rate-limits after the configured budget", %{conn: conn} do
      _ = user_fixture(%{username: "bob", password: "right-password-1"})

      for _ <- 1..10 do
        post(conn, ~p"/api/v1/sessions/issue_token", %{
          "username" => "bob",
          "password" => "wrong"
        })
      end

      response =
        post(conn, ~p"/api/v1/sessions/issue_token", %{
          "username" => "bob",
          "password" => "wrong"
        })

      assert response.status == 429
      assert Jason.decode!(response.resp_body)["error"] == "rate_limited"
    end
  end
end
