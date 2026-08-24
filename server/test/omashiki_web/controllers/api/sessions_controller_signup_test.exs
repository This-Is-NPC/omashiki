defmodule OmashikiWeb.Api.SessionsControllerSignupTest do
  use OmashikiWeb.ConnCase, async: false

  describe "POST /api/v1/sessions/signup" do
    @tag :unauthenticated
    test "creates the operator + returns a fresh token", %{conn: conn} do
      response =
        post(conn, ~p"/api/v1/sessions/signup", %{
          "email" => "first@example.com",
          "username" => "first",
          "password" => "first-password-1",
          "name" => "CLI on test"
        })

      assert response.status == 201
      payload = Jason.decode!(response.resp_body)
      assert is_binary(payload["data"]["token"])
      assert payload["data"]["user"]["email"] == "first@example.com"
      assert payload["data"]["user"]["username"] == "first"
      assert is_binary(payload["data"]["user"]["id"])
      assert Omashiki.Accounts.count() == 1
    end

    @tag :unauthenticated
    test "returns 409 signup_closed once a user exists", %{conn: conn} do
      _ = user_fixture()

      response =
        post(conn, ~p"/api/v1/sessions/signup", %{
          "email" => "second@example.com",
          "username" => "second",
          "password" => "second-password-1"
        })

      assert response.status == 409
      payload = Jason.decode!(response.resp_body)
      assert payload["error"] == "signup_closed"
      assert payload["message"] =~ "issue_token"
    end

    @tag :unauthenticated
    test "returns 422 validation_error on invalid input", %{conn: conn} do
      response =
        post(conn, ~p"/api/v1/sessions/signup", %{
          "email" => "not-an-email",
          "username" => "",
          "password" => "abc"
        })

      assert response.status == 422
      payload = Jason.decode!(response.resp_body)
      assert payload["error"] == "validation_error"
      assert is_map(payload["details"])
      # both an email format error and a length error should surface
      assert Map.has_key?(payload["details"], "email")
      assert Map.has_key?(payload["details"], "username")
    end

    @tag :unauthenticated
    test "second call after a successful signup also returns 409", %{conn: conn} do
      first =
        post(conn, ~p"/api/v1/sessions/signup", %{
          "email" => "first@example.com",
          "username" => "first",
          "password" => "first-password-1"
        })

      assert first.status == 201

      second =
        post(conn, ~p"/api/v1/sessions/signup", %{
          "email" => "second@example.com",
          "username" => "second",
          "password" => "second-password-1"
        })

      assert second.status == 409
      assert Jason.decode!(second.resp_body)["error"] == "signup_closed"
    end
  end
end
