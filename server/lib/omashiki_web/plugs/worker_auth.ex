defmodule OmashikiWeb.Plugs.WorkerAuth do
  @moduledoc """
  Authenticates `/internal/work/*` via the manager-issued worker token.

  Operator API tokens and session cookies are rejected here; the worker token
  must not be accepted by `BearerAuth`.
  """

  import Plug.Conn

  alias Omashiki.Worker.Tokens

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    cond do
      not Tokens.configured?() ->
        send_forbidden(conn)

      is_nil(extract_bearer(conn)) ->
        send_unauthorized(conn)

      Tokens.valid?(extract_bearer(conn)) ->
        conn

      true ->
        send_forbidden(conn)
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp send_unauthorized(conn) do
    send_error(conn, 401, "missing_token", "Worker bearer token required")
  end

  defp send_forbidden(conn) do
    send_error(conn, 403, "invalid_token", "Worker bearer token is not valid")
  end

  defp send_error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{code: code, message: message}}))
    |> halt()
  end
end
