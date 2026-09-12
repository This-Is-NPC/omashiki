defmodule OmashikiWeb.Plugs.TokenExpiryHeader do
  @moduledoc "Advertise token expiry on every authenticated API response."

  @behaviour Plug

  import Plug.Conn

  alias Omashiki.ApiTokens.Token

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.assigns[:current_token] do
      %Token{expires_at: %DateTime{} = expires_at} ->
        register_before_send(conn, fn conn ->
          put_resp_header(conn, "x-token-expires-at", DateTime.to_iso8601(expires_at))
        end)

      _ ->
        conn
    end
  end
end
