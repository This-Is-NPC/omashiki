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
