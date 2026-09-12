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
      assert_schema(Jason.decode!(response.resp_body), "Problem", OmashikiWeb.ApiSpec.spec())
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
      assert_schema(payload, "TokenResponse", OmashikiWeb.ApiSpec.spec())
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
      assert_schema(Jason.decode!(response.resp_body), "Problem", OmashikiWeb.ApiSpec.spec())
    end

    @tag :unauthenticated
    test "issue_token budget is per address, not typed identifier", %{conn: conn} do
      _ = user_fixture(%{username: "bob", password: "right-password-1"})
      _ = user_fixture(%{username: "ann", password: "right-password-2"})

      for _ <- 1..10 do
        post(
          conn,
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "bob", "password" => "wrong"})
        )
      end

      via_ann =
        post(
          conn,
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "ann", "password" => "wrong"})
        )

      assert via_ann.status == 429
      assert_schema(Jason.decode!(via_ann.resp_body), "Problem", OmashikiWeb.ApiSpec.spec())
    end

    @tag :unauthenticated
    test "ignores X-Forwarded-For unless forwarded headers are trusted", %{conn: conn} do
      _ = user_fixture(%{username: "bob", password: "right-password-1"})

      for _ <- 1..10 do
        post(
          conn,
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "bob", "password" => "wrong"})
        )
      end

      forwarded =
        conn
        |> Plug.Conn.put_req_header("x-forwarded-for", "9.9.9.9")
        |> post(
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "bob", "password" => "wrong"})
        )

      assert forwarded.status == 429
    end

    @tag :unauthenticated
    test "uses X-Forwarded-For when forwarded headers are trusted", %{conn: conn} do
      previous = Application.get_env(:omashiki, :http_forwarded)
      Application.put_env(:omashiki, :http_forwarded, true)
      on_exit(fn -> Application.put_env(:omashiki, :http_forwarded, previous) end)

      _ = user_fixture(%{username: "bob", password: "right-password-1"})

      for _ <- 1..10 do
        post(
          conn,
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "bob", "password" => "wrong"})
        )
      end

      forwarded =
        conn
        |> Plug.Conn.put_req_header("x-forwarded-for", "8.8.8.8, 9.9.9.9")
        |> post(
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "bob", "password" => "wrong"})
        )

      assert forwarded.status == 401
      assert Jason.decode!(forwarded.resp_body)["code"] == "invalid_credentials"

      spoofed =
        conn
        |> Plug.Conn.put_req_header("x-forwarded-for", "not-an-ip")
        |> post(
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "bob", "password" => "wrong"})
        )

      assert spoofed.status == 429
    end

    @tag :unauthenticated
    test "uses the last X-Forwarded-For header line as the trusted hop", %{conn: conn} do
      previous = Application.get_env(:omashiki, :http_forwarded)
      Application.put_env(:omashiki, :http_forwarded, true)
      on_exit(fn -> Application.put_env(:omashiki, :http_forwarded, previous) end)

      _ = user_fixture(%{username: "bob", password: "right-password-1"})

      for _ <- 1..10 do
        conn
        |> Plug.Conn.put_req_header("x-forwarded-for", "8.8.8.8, 9.9.9.9")
        |> post(
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "bob", "password" => "wrong"})
        )
      end

      spoofed_first_line =
        conn
        |> Map.update!(:req_headers, fn headers ->
          headers ++ [{"x-forwarded-for", "1.2.3.4"}, {"x-forwarded-for", "9.9.9.9"}]
        end)
        |> post(
          ~p"/api/v1/sessions/issue_token",
          token_grants(%{"username" => "bob", "password" => "wrong"})
        )

      assert spoofed_first_line.status == 429
    end
  end
end
