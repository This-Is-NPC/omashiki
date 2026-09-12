defmodule OmashikiWeb.Api.SessionsControllerSignupTest do
  use OmashikiWeb.ConnCase, async: false

  @moduletag :api

  describe "POST /api/v1/sessions/signup" do
    @tag :unauthenticated
    test "creates the operator + returns a fresh token", %{conn: conn} do
      response =
        post(conn, ~p"/api/v1/sessions/signup", token_grants(%{
          "email" => "first@example.com",
          "username" => "first",
          "password" => "first-password-1",
          "name" => "CLI on test"
        }))

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
        post(conn, ~p"/api/v1/sessions/signup", token_grants(%{
          "email" => "second@example.com",
          "username" => "second",
          "password" => "second-password-1"
        }))

      assert response.status == 409
      payload = Jason.decode!(response.resp_body)
      assert payload["code"] == "signup_closed"
    end

    @tag :unauthenticated
    test "returns 422 validation_error on invalid input", %{conn: conn} do
      response =
        post(conn, ~p"/api/v1/sessions/signup", token_grants(%{
          "email" => "not-an-email",
          "username" => "",
          "password" => "abc"
        }))

      assert response.status == 422
      payload = Jason.decode!(response.resp_body)
      assert payload["code"] == "invalid_request"
    end

    @tag :unauthenticated
    test "second call after a successful signup also returns 409", %{conn: conn} do
      first =
        post(conn, ~p"/api/v1/sessions/signup", token_grants(%{
          "email" => "first@example.com",
          "username" => "first",
          "password" => "first-password-1"
        }))

      assert first.status == 201

      second =
        post(conn, ~p"/api/v1/sessions/signup", token_grants(%{
          "email" => "second@example.com",
          "username" => "second",
          "password" => "second-password-1"
        }))

      assert second.status == 409
      assert Jason.decode!(second.resp_body)["code"] == "signup_closed"
    end
  end
end
