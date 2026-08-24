defmodule OmashikiWeb.UserController do
  @moduledoc """
  Owns the cookie-session lifecycle for human operators.

  - `GET /signup` is rendered ONLY while no user exists. Subsequent visits
    return `404` so the surface cannot be probed.
  - `POST /signup` registers the first user inside a serializable
    transaction.
  - `GET /login` and `POST /login` accept email-or-username + password.
  - `DELETE /logout` drops the session.
  """

  use OmashikiWeb, :controller

  alias Omashiki.Accounts

  ## ---------- signup ---------------------------------------------------

  def new_signup(conn, _params) do
    if Accounts.signup_open?() do
      changeset = Accounts.User.registration_changeset(%Accounts.User{}, %{})

      conn
      |> put_layout(false)
      |> render(:signup, changeset: changeset, layout: false)
    else
      conn
      |> put_status(:not_found)
      |> put_view(OmashikiWeb.ErrorHTML)
      |> render(:"404")
      |> halt()
    end
  end

  def create_signup(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> configure_session(renew: true)
        |> redirect(to: "/")

      {:error, :registration_closed} ->
        conn
        |> put_status(:not_found)
        |> put_view(OmashikiWeb.ErrorHTML)
        |> render(:"404")
        |> halt()

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, "Please fix the errors below.")
        |> put_layout(false)
        |> render(:signup, changeset: changeset, layout: false)
    end
  end

  ## ---------- login / logout -------------------------------------------

  def new_session(conn, params) do
    reason = Map.get(params, "reason")

    cond do
      Accounts.signup_open?() ->
        redirect(conn, to: "/signup")

      true ->
        conn
        |> put_layout(false)
        |> render(:login, reason: reason, identifier: "", layout: false)
    end
  end

  def create_session(conn, %{"identifier" => identifier, "password" => password}) do
    case Accounts.authenticate(identifier, password) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> configure_session(renew: true)
        |> redirect(to: "/")

      {:error, :invalid_credentials} ->
        # The `:reason` assign drives the dedicated banner in the login
        # template; don't also set a flash — they'd render two identical
        # banners stacked.
        conn
        |> put_layout(false)
        |> render(:login, reason: "invalid", identifier: identifier || "", layout: false)
    end
  end

  def create_session(conn, _params) do
    conn
    |> put_flash(:error, "Identifier and password are required.")
    |> redirect(to: "/login")
  end

  def delete_session(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login?reason=signed_out")
  end
end
