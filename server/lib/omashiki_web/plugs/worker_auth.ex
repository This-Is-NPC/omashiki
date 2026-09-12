defmodule OmashikiWeb.Plugs.WorkerAuth do
  @moduledoc """
  Authenticates `/internal/work/*` via the manager-issued worker token.

  Operator API tokens and session cookies are rejected here; the worker token
  must not be accepted by `BearerAuth`.
  """

  import Plug.Conn

  alias Omashiki.Worker.Tokens
  alias OmashikiWeb.Api.Problem

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
    Problem.halt(conn, "missing_token")
  end

  defp send_forbidden(conn) do
    Problem.halt(conn, "invalid_token")
  end
end
