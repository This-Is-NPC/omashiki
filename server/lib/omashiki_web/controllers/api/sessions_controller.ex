defmodule OmashikiWeb.Api.SessionsController do
  @moduledoc "Credential exchange and token rotation."

  use OmashikiWeb.Api.Controller

  alias Omashiki.{Accounts, ApiTokens}
  alias Omashiki.Maps
  alias OmashikiWeb.Api.Conn, as: ApiConn
  alias OmashikiWeb.RateLimiter

  @rate_limit_max Application.compile_env(:omashiki, [__MODULE__, :rate_limit_max], 10)
  @rate_limit_per_ms Application.compile_env(:omashiki, [__MODULE__, :rate_limit_per_ms], 60_000)

  tags(["sessions"])

  operation(:issue_token,
    summary: "Exchange credentials for an API token",
    security: [],
    request_body: {"Credentials", "application/json", Schemas.IssueTokenRequest},
    responses: %{
      200 => {"Token", "application/json", Schemas.TokenResponse},
      401 => {"Unauthorized", "application/problem+json", Schemas.Problem}
    }
  )

  def issue_token(conn, _params) do
    attrs = Maps.stringify_keys(conn.body_params)

    with :ok <- check_rate(conn),
         {:ok, user} <- authenticate(attrs),
         {:ok, token, plaintext} <- ApiTokens.create_for_user(user, token_attrs(attrs, "CLI")) do
      ApiConn.audit(conn, token, "issue")
      json(conn, %{data: token_json(token, plaintext)})
    end
  end

  operation(:signup,
    summary: "Create the first operator and token",
    security: [],
    request_body: {"Signup", "application/json", Schemas.SignupRequest},
    responses: %{
      201 => {"Created", "application/json", Schemas.SignupResponse},
      409 => {"Closed", "application/problem+json", Schemas.Problem}
    }
  )

  def signup(conn, _params) do
    attrs = Maps.stringify_keys(conn.body_params)

    user_attrs = %{
      "email" => attrs["email"],
      "username" => attrs["username"],
      "password" => attrs["password"]
    }

    case Accounts.register_with_token(user_attrs, token_attrs(attrs, "CLI")) do
      {:ok, {user, token, plaintext}} ->
        ApiConn.audit(conn, token, "issue")

        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            token: plaintext,
            user: %{id: user.id, email: user.email, username: user.username}
          }
        })

      {:error, :registration_closed} ->
        {:error, :signup_closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  operation(:rotate_token,
    summary: "Issue a new token and revoke the current one",
    security: [%{"bearer" => ["submit"]}],
    responses: %{
      200 => {"Token", "application/json", Schemas.TokenResponse}
    }
  )

  def rotate_token(conn, _params) do
    token = conn.assigns[:current_token]

    cond do
      is_nil(token) ->
        {:error, :token_required}

      true ->
        case ApiTokens.rotate(token) do
          {:ok, new_token, plaintext} ->
            ApiConn.audit(conn, token, "rotate")
            json(conn, %{data: token_json(new_token, plaintext)})

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp authenticate(%{"username" => username, "password" => password}) do
    case Accounts.authenticate(username, password) do
      {:ok, user} -> {:ok, user}
      {:error, :invalid_credentials} -> {:error, :invalid_credentials}
    end
  end

  defp token_attrs(attrs, default_name) do
    %{
      name: String.slice(attrs["name"] || default_name, 0, 80),
      scopes: attrs["scopes"],
      allowed_environments: attrs["allowed_environments"],
      max_active_jobs: attrs["max_active_jobs"],
      ttl_days: attrs["ttl_days"]
    }
  end

  defp token_json(token, plaintext) do
    %{
      token: plaintext,
      name: token.name,
      expires_at: DateTime.to_iso8601(token.expires_at),
      scopes: token.scopes,
      allowed_environments: token.allowed_environments,
      max_active_jobs: token.max_active_jobs
    }
  end

  defp check_rate(conn) do
    case RateLimiter.hit("issue_token", ApiConn.client_ip_or_unknown(conn),
           max: @rate_limit_max,
           per_ms: @rate_limit_per_ms
         ) do
      {:ok, _} -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end
end
