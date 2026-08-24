defmodule OmashikiWeb.Api.SessionsController do
  @moduledoc """
  Credential exchange used by `omashiki login --username/--password`.

  POST /api/v1/sessions/issue_token
    body: { "username": "...", "password": "...", "name": "optional label" }

  On valid credentials, mints an all-projects token labeled
  `name || "CLI on <hostname>"` (the client supplies its hostname via
  `name`) and returns the plaintext exactly once.

  POST /api/v1/sessions/signup
    body: { "email": "...", "username": "...", "password": "..." }

  First-boot bootstrap for the CLI wizard. Creates the operator account
  and mints an all-projects token in one round-trip. Gated by
  `Accounts.signup_open?/0` — returns 409 once a user exists.
  """

  use OmashikiWeb, :controller

  alias Omashiki.{Accounts, ApiTokens}
  alias OmashikiWeb.RateLimiter

  @rate_limit_max Application.compile_env(:omashiki, [__MODULE__, :rate_limit_max], 10)
  @rate_limit_per_ms Application.compile_env(:omashiki, [__MODULE__, :rate_limit_per_ms], 60_000)

  def issue_token(conn, params) do
    username = Map.get(params, "username")
    password = Map.get(params, "password")
    label = Map.get(params, "name") || "CLI"

    with :ok <- check_rate(conn) do
      authenticate_and_issue(conn, username, password, label)
    end
  end

  defp check_rate(conn) do
    bucket = client_ip(conn) <> "|" <> (conn.params["username"] || "")

    case RateLimiter.hit("issue_token", bucket,
           max: @rate_limit_max,
           per_ms: @rate_limit_per_ms
         ) do
      {:ok, _} ->
        :ok

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate_limited", retry_after_ms: @rate_limit_per_ms})
    end
  end

  defp client_ip(conn) do
    case conn.remote_ip do
      nil -> "unknown"
      ip -> ip |> :inet.ntoa() |> to_string()
    end
  rescue
    _ -> "unknown"
  end

  defp authenticate_and_issue(conn, username, password, label) do
    case Accounts.authenticate(username, password) do
      {:ok, user} ->
        case ApiTokens.create_for_user(user, %{
               name: String.slice(label, 0, 80)
             }) do
          {:ok, token, plaintext} ->
            json(conn, %{
              data: %{
                token: plaintext,
                name: token.name,
                expires_at: nil
              }
            })

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "could_not_issue_token", detail: inspect(reason)})
        end

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_credentials"})
    end
  end

  def signup(conn, params) do
    email = Map.get(params, "email")
    username = Map.get(params, "username")
    password = Map.get(params, "password")
    label = Map.get(params, "name") || "CLI"

    case Accounts.register_user(%{
           "email" => email,
           "username" => username,
           "password" => password
         }) do
      {:ok, user} ->
        case ApiTokens.create_for_user(user, %{
               name: String.slice(label, 0, 80)
             }) do
          {:ok, _token, plaintext} ->
            conn
            |> put_status(:created)
            |> json(%{
              data: %{
                token: plaintext,
                user: %{id: user.id, email: user.email, username: user.username}
              }
            })

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "could_not_issue_token", detail: inspect(reason)})
        end

      {:error, :registration_closed} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: "signup_closed",
          message: "Operator already exists. Use POST /api/v1/sessions/issue_token."
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation_error", details: changeset_errors(changeset)})
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
