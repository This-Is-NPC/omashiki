defmodule OmashikiWeb.AuthHooks do
  @moduledoc """
  LiveView `on_mount` hook that gates every authenticated route on a logged-in
  `current_user`.

  Browsers obtain `:user_id` in the session via the login form. The session
  cookie persists for the duration of the browser session; the user re-logs
  in if the cookie is dropped.

  When `:user_id` is missing or refers to a deleted user the LiveView is
  redirected to `/login`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias Omashiki.Accounts

  def on_mount(:require_user, _params, session, socket) do
    if OmashikiWeb.AuthMode.disabled?() do
      mount_as_local_owner(socket)
    else
      require_session_user(session, socket)
    end
  end

  @doc """
  `:require_user`, plus a loopback check when login is disabled.

  Used only by `/dashboard`. Every other operator route exposes queue state,
  which is what `auth.enabled = false` deliberately opens up. LiveDashboard
  exposes process state, message queues, stacktraces and ETS contents, and
  "the operator asked for auth off" is not consent to serve that to the LAN —
  `app.host` defaults to `0.0.0.0` so agent containers can reach the gateway,
  which means every peer on the network can reach this route too.

  `OmashikiWeb.Plugs.BearerAuth` already resolves the same tension the same way
  for the API: `:none` is honoured only for loopback peers. This is that rule,
  applied to the one browser route that needs it, and to nothing else.

  The address comes from `:peer_data` rather than `remote_ip` because that is
  the only form available over the websocket. Behind a reverse proxy every peer
  would look local — so would `remote_ip` unless the proxy sets forwarded
  headers, and this application ships no proxy configuration either way.
  """
  def on_mount(:require_operator_console, params, session, socket) do
    case on_mount(:require_user, params, session, socket) do
      {:cont, socket} -> require_local_peer(socket)
      halted -> halted
    end
  end

  defp require_local_peer(socket) do
    if OmashikiWeb.AuthMode.disabled?() and not local_peer?(socket) do
      {:halt, redirect(socket, to: "/")}
    else
      {:cont, socket}
    end
  end

  # `get_connect_info/2` reads the peer from the conn on the dead render and
  # from the socket once connected, so both halves of a LiveView mount are
  # covered. Anything else — no peer information at all — is treated as remote:
  # this gate only ever runs with login off, where failing open would publish
  # the BEAM.
  defp local_peer?(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} -> OmashikiWeb.AuthMode.loopback_ip?(address)
      _ -> false
    end
  rescue
    _ -> false
  end

  # `auth.enabled = false` in omashiki.toml: no login screen, act as the local
  # owner. Unlike the API path this does not check for loopback — the operator
  # asked for auth off, and honouring that on one surface but not the other
  # would be a flag that only half works.
  defp mount_as_local_owner(socket) do
    case Accounts.local_owner() do
      %Accounts.User{} = user ->
        {:cont, socket |> assign(:current_user, user) |> assign(:authenticated, true)}

      nil ->
        {:halt, redirect(socket, to: "/login?reason=no_local_owner")}
    end
  end

  defp require_session_user(session, socket) do
    case fetch_user(session) do
      {:ok, user} ->
        {:cont, socket |> assign(:current_user, user) |> assign(:authenticated, true)}

      :missing ->
        {:halt, redirect(socket, to: "/login")}

      :stale ->
        {:halt, redirect(socket, to: "/login?reason=invalid")}
    end
  end

  defp fetch_user(session) do
    case Map.get(session, "user_id") do
      nil ->
        :missing

      user_id when is_binary(user_id) ->
        case Accounts.get_user(user_id) do
          nil -> :stale
          user -> {:ok, user}
        end
    end
  end
end
