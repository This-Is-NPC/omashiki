defmodule Omashiki.Identities.GithubApp do
  @moduledoc """
  The house acting as a GitHub App.

  Everything here runs in the manager process: the App JWT is signed with the
  private key held by `Omashiki.Config.identities/0`, exchanged for a
  short-lived installation token, and that token is used for REST calls on
  the agent's behalf. Neither the key nor the installation token is ever
  handed to a sandbox, a worker, or a log line.

  Installation tokens are cached per identity until shortly before they
  expire; a cached token is dropped when the identity's public view changes.
  """

  alias Omashiki.Config.Identity
  alias Omashiki.Identities.Http

  @table :omashiki_identity_tokens
  @jwt_ttl_seconds 540
  @jwt_skew_seconds 60
  @refresh_margin_seconds 60

  @doc "GitHub REST base URL. Overridable for GitHub Enterprise and tests."
  def api_base_url do
    Application.get_env(:omashiki, :github_api_base_url) ||
      System.get_env("OMASHIKI_GITHUB_API_BASE_URL") ||
      "https://api.github.com"
  end

  @doc "Sign the App JWT (RS256, 9 minute lifetime) for one identity."
  def jwt(%Identity{kind: "github-app"} = identity, now \\ System.os_time(:second)) do
    key = decode_private_key!(identity.private_key)

    header = encode(%{"alg" => "RS256", "typ" => "JWT"})

    payload =
      encode(%{
        "iat" => now - @jwt_skew_seconds,
        "exp" => now + @jwt_ttl_seconds,
        "iss" => identity.app_id
      })

    input = header <> "." <> payload
    input <> "." <> Base.url_encode64(:public_key.sign(input, :sha256, key), padding: false)
  end

  @doc "Installation token for one identity, minted or served from cache."
  def installation_token(%Identity{kind: "github-app"} = identity, opts \\ []) do
    now = Keyword.get(opts, :now, System.os_time(:second))
    ensure_table()

    public = Identity.public(identity)

    case :ets.lookup(@table, identity.name) do
      [{_, token, expires_at, ^public}] when expires_at - @refresh_margin_seconds > now ->
        {:ok, token}

      _ ->
        mint_installation_token(identity, now)
    end
  end

  @doc "Forget cached installation tokens."
  def clear_cache do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  One authenticated REST call as the installation.

  `path` is relative to the API base (`/repos/o/r/issues/1/comments`). Returns
  the status and the decoded JSON body, or the raw body when not JSON.
  """
  def request(%Identity{} = identity, method, path, body \\ nil)
      when method in [:get, :post, :patch, :put, :delete] and is_binary(path) do
    with {:ok, token} <- installation_token(identity) do
      headers = [
        {"authorization", "token " <> token},
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "omashiki-identities/1"}
      ]

      encoded = if is_nil(body), do: nil, else: Jason.encode!(body)

      case Http.request(method, api_base_url() <> path, headers, encoded) do
        {:ok, status, raw} -> {:ok, status, decode_body(raw)}
        {:error, reason} -> {:error, {:github_unreachable, reason}}
      end
    end
  end

  defp mint_installation_token(identity, now) do
    headers = [
      {"authorization", "Bearer " <> jwt(identity, now)},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "omashiki-identities/1"}
    ]

    path = "/app/installations/#{identity.installation_id}/access_tokens"

    case Http.request(:post, api_base_url() <> path, headers, "{}") do
      {:ok, 201, raw} ->
        with {:ok, %{"token" => token} = decoded} when is_binary(token) <- Jason.decode(raw) do
          expires_at = parse_expiry(decoded["expires_at"], now)
          :ets.insert(@table, {identity.name, token, expires_at, Identity.public(identity)})
          {:ok, token}
        else
          _ -> {:error, :installation_token_invalid}
        end

      {:ok, status, _raw} ->
        {:error, {:installation_token_http, status}}

      {:error, reason} ->
        {:error, {:github_unreachable, reason}}
    end
  rescue
    error in ArgumentError -> {:error, {:private_key_invalid, error.message}}
  end

  defp parse_expiry(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> DateTime.to_unix(at)
      _ -> now + 3600
    end
  end

  defp parse_expiry(_, now), do: now + 3600

  defp decode_body(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      _ -> raw
    end
  end

  defp decode_private_key!(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        case :public_key.pem_entry_decode(entry) do
          {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key ->
            key

          _ ->
            raise ArgumentError, "github-app private_key must be an RSA private key (PKCS#1 PEM)"
        end

      [] ->
        raise ArgumentError, "github-app private_key is not PEM"
    end
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  @doc false
  # Owned by whichever long-lived process calls this first (the application
  # starter at boot); a request process creating it would take it down with it.
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end
end
