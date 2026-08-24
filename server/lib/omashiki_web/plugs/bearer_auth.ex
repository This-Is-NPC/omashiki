defmodule OmashikiWeb.Plugs.BearerAuth do
  @moduledoc """
  Authenticates `/api/v1/*` (except `/health`) via the
  bearer token issued from `/settings/tokens`.

  Token sources (checked in order):

    1. `Authorization: Bearer <plaintext>` header.
    2. `?token=<plaintext>` query parameter (used by the WebSocket
       upgrade path that cannot set arbitrary headers).
    3. `:user_id` session cookie — kept as a fallback for the few
       browser-driven REST hits that come from the LiveView surface.

  On a valid bearer match the plug attaches:

    * `:current_user` — the user the token belongs to
    * `:current_token` — the token row (so downstream plugs / tools can
      consult the owner relationship)
    * `:authenticated` — `true`, kept for back-compat with downstream
      assertions

  …and fires off an async `last_used_at` bump.

  On failure:

    * `401` when no credential was supplied (or `auth_mode: :none` from
      a non-loopback peer — see `OmashikiWeb.AuthMode`).
    * `403` when the supplied credential is invalid.

  When `auth_mode: :none` and the peer is loopback with no credential,
  the sole registered operator is assigned (local laptop only).

  The token plaintext is never logged. Outbound logs are scrubbed by
  `OmashikiWeb.LoggerFilter`.
  """

  import Plug.Conn

  require Logger

  alias Omashiki.{Accounts, ApiTokens}
  alias OmashikiWeb.AuthMode

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case extract_credential(conn) do
      {:bearer, plaintext} ->
        authenticate_bearer(conn, plaintext)

      {:session, user_id} ->
        authenticate_session(conn, user_id)

      :missing ->
        maybe_auth_none(conn)
    end
  end

  defp maybe_auth_none(conn) do
    if AuthMode.mode() == :none do
      if AuthMode.loopback_ip?(conn.remote_ip) do
        case Accounts.sole_user() do
          %Accounts.User{} = user ->
            conn
            |> assign(:current_user, user)
            |> assign(:current_token, nil)
            |> assign(:authenticated, true)
            |> assign(:auth_mode_none, true)

          nil ->
            Logger.debug("[BearerAuth] auth_mode :none but no sole user yet")
            send_unauthorized(conn)
        end
      else
        Logger.debug(
          "[BearerAuth] auth_mode :none denied for non-loopback #{inspect(conn.remote_ip)}"
        )

        send_none_loopback_only(conn)
      end
    else
      Logger.debug("[BearerAuth] missing credential on #{conn.method} #{conn.request_path}")
      send_unauthorized(conn)
    end
  end

  defp authenticate_bearer(conn, plaintext) do
    case ApiTokens.find_active_by_plaintext(plaintext) do
      {:ok, token} ->
        ApiTokens.record_use(token)

        conn
        |> assign(:current_user, token.user)
        |> assign(:current_token, token)
        |> assign(:authenticated, true)

      :error ->
        Logger.debug("[BearerAuth] bad bearer on #{conn.method} #{conn.request_path}")
        send_forbidden(conn)
    end
  end

  defp authenticate_session(conn, user_id) do
    case Accounts.get_user(user_id) do
      nil ->
        Logger.debug("[BearerAuth] stale session user on #{conn.method} #{conn.request_path}")
        send_forbidden(conn)

      user ->
        conn
        |> assign(:current_user, user)
        |> assign(:current_token, nil)
        |> assign(:authenticated, true)
    end
  end

  defp extract_credential(conn) do
    conn = fetch_query_params(conn)

    cond do
      bearer = bearer_from_header(conn) -> {:bearer, bearer}
      query = conn.query_params["token"] -> {:bearer, query}
      session = get_session_user_id(conn) -> {:session, session}
      true -> :missing
    end
  end

  defp bearer_from_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      ["bearer " <> token | _] -> token
      _ -> nil
    end
  end

  defp get_session_user_id(conn) do
    try do
      get_session(conn, :user_id)
    rescue
      _ -> nil
    end
  end

  defp send_unauthorized(conn) do
    send_error(conn, 401, "missing_token", "Bearer token required")
  end

  defp send_none_loopback_only(conn) do
    send_error(
      conn,
      401,
      "auth_mode_none_loopback_only",
      "auth_mode :none is only valid on loopback; Bearer required on LAN"
    )
  end

  defp send_forbidden(conn) do
    send_error(conn, 403, "invalid_token", "Bearer token is not valid")
  end

  defp send_error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{code: code, message: message, details: %{}}}))
    |> halt()
  end
end
