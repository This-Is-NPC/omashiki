defmodule OmashikiWeb.Api.Conn do
  @moduledoc "Shared request helpers for public API controllers."

  alias Omashiki.ApiTokens
  alias OmashikiWeb.Api.Problem

  def actor(conn), do: conn.assigns[:current_token] || conn.assigns[:current_user]

  def client_ip(conn) do
    if Application.get_env(:omashiki, :http_forwarded, false) do
      forwarded_client_ip(conn) || remote_ip(conn)
    else
      remote_ip(conn)
    end
  end

  def client_ip_or_unknown(conn), do: client_ip(conn) || "unknown"

  defp remote_ip(conn) do
    case conn.remote_ip do
      nil -> nil
      tuple -> tuple |> :inet.ntoa() |> to_string()
    end
  rescue
    _ -> nil
  end

  defp forwarded_client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [value | _] ->
        value
        |> String.split(",", parts: 2)
        |> hd()
        |> String.trim()
        |> case do
          "" -> nil
          ip -> ip
        end

      _ ->
        nil
    end
  end

  def last_event_id(conn) do
    case Plug.Conn.get_req_header(conn, "last-event-id") do
      [] -> nil
      [value] -> value
      _ -> :invalid_cursor
    end
  end

  def audit(conn, token, action, opts \\ []) do
    ApiTokens.Audit.record(
      token,
      action,
      Keyword.merge(
        [request_id: Problem.request_id(conn), ip: client_ip(conn)],
        opts
      )
    )
  end
end
