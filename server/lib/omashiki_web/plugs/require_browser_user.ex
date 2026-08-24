defmodule OmashikiWeb.Plugs.RequireBrowserUser do
  @moduledoc """
  Browser-session gate for routes that cannot sit inside the `:authenticated`
  `live_session` routes, which always open their own session.

  Mirrors `OmashikiWeb.AuthHooks.require_user/3`: missing or stale `user_id`
  redirects to `/login`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Omashiki.Accounts

  def init(opts), do: opts

  def call(conn, opts) do
    if OmashikiWeb.AuthMode.disabled?() do
      # Mirrors AuthHooks: auth off means no login, act as the local owner.
      case Accounts.local_owner() do
        %Accounts.User{} = user -> assign(conn, :current_user, user)
        nil -> conn |> redirect(to: "/login?reason=no_local_owner") |> halt()
      end
    else
      require_session_user(conn, opts)
    end
  end

  defp require_session_user(conn, _opts) do
    case get_session(conn, "user_id") do
      nil ->
        conn |> redirect(to: "/login") |> halt()

      user_id when is_binary(user_id) ->
        case Accounts.get_user(user_id) do
          nil ->
            conn |> redirect(to: "/login?reason=invalid") |> halt()

          user ->
            assign(conn, :current_user, user)
        end
    end
  end
end
