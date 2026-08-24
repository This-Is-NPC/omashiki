defmodule OmashikiWeb.UserControllerTest do
  use OmashikiWeb.ConnCase, async: false

  describe "GET /signup" do
    @tag :unauthenticated
    test "renders the form when no users exist", %{conn: conn} do
      response = get(conn, ~p"/signup")
      assert html_response(response, 200) =~ "Create the operator"
    end

    @tag :unauthenticated
    test "form inputs carry the expected name attributes (regression: text_input/field)",
         %{conn: conn} do
      response = get(conn, ~p"/signup")
      body = html_response(response, 200)

      inputs =
        body
        |> Floki.parse_document!()
        |> Floki.find("form input[name]")
        |> Enum.map(fn input -> input |> Floki.attribute("name") |> hd() end)

      assert "user[email]" in inputs
      assert "user[username]" in inputs
      assert "user[password]" in inputs
    end

    @tag :unauthenticated
    test "returns 404 once a user exists", %{conn: conn} do
      _ = user_fixture()
      response = get(conn, ~p"/signup")
      assert response.status == 404
    end
  end

  describe "POST /signup" do
    @tag :unauthenticated
    test "registers the first user, sets the session and redirects to /",
         %{conn: conn} do
      params = %{
        "user" => %{
          "email" => "first@example.com",
          "username" => "first",
          "password" => "first-password-1"
        }
      }

      response = post(conn, ~p"/signup", params)

      assert redirected_to(response) == "/"
      assert get_session(response, :user_id)
      assert Omashiki.Accounts.count() == 1
    end

    @tag :unauthenticated
    test "rejects a second signup with 404 (registration_closed)", %{conn: conn} do
      _ = user_fixture()

      params = %{
        "user" => %{
          "email" => "second@example.com",
          "username" => "second",
          "password" => "second-password"
        }
      }

      response = post(conn, ~p"/signup", params)
      assert response.status == 404
    end

    @tag :unauthenticated
    test "re-renders the form with errors on validation failure", %{conn: conn} do
      params = %{"user" => %{"email" => "x", "username" => "", "password" => "abc"}}

      response = post(conn, ~p"/signup", params)
      assert html_response(response, 200) =~ "Create the operator"
      assert response.resp_body =~ "Must be a valid email"
    end
  end

  describe "GET /login" do
    @tag :unauthenticated
    test "redirects to /signup when no users exist yet", %{conn: conn} do
      response = get(conn, ~p"/login")
      assert redirected_to(response) == "/signup"
    end

    @tag :unauthenticated
    test "renders the login form once at least one user exists", %{conn: conn} do
      _ = user_fixture()
      response = get(conn, ~p"/login")
      assert html_response(response, 200) =~ "Sign in"
    end
  end

  describe "POST /login" do
    setup do
      user = user_fixture(%{username: "loginuser", password: "secret-pass-1"})
      %{user: user}
    end

    @tag :unauthenticated
    test "valid credentials set the session and redirect to /",
         %{conn: conn, user: user} do
      response =
        post(conn, ~p"/login", %{
          "identifier" => user.username,
          "password" => "secret-pass-1"
        })

      assert redirected_to(response) == "/"
      assert get_session(response, :user_id) == user.id
    end

    @tag :unauthenticated
    test "wrong password re-renders the form with a generic error",
         %{conn: conn} do
      response =
        post(conn, ~p"/login", %{
          "identifier" => "loginuser",
          "password" => "nope"
        })

      assert html_response(response, 200) =~ "Invalid credentials"
      refute get_session(response, :user_id)
    end

    @tag :unauthenticated
    test "wrong identifier still surfaces the same generic error",
         %{conn: conn} do
      response =
        post(conn, ~p"/login", %{
          "identifier" => "ghost",
          "password" => "anything"
        })

      assert html_response(response, 200) =~ "Invalid credentials"
      refute get_session(response, :user_id)
    end

    @tag :unauthenticated
    test "missing identifier or password redirects with a flash", %{conn: conn} do
      response = post(conn, ~p"/login", %{})
      assert redirected_to(response) == "/login"
    end
  end

  describe "DELETE /logout" do
    test "drops the session and redirects to /login with a signed_out reason",
         %{conn: conn} do
      response = delete(conn, ~p"/logout")
      assert redirected_to(response) == "/login?reason=signed_out"
      assert response.private[:plug_session_info] == :drop
    end
  end
end
