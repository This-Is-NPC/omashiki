defmodule OmashikiWeb.Api.ToolsProxyController do
  @moduledoc """
  HTTP front for `Omashiki.Tools.Proxy`. Provisioned agents are configured
  to call this with a job-bound bearer token (not an operator API token).

  The proxy validates the signed job claim and applies the environment
  capability allowlist before forwarding any request.
  """

  use OmashikiWeb, :controller

  alias Omashiki.Tools.Proxy

  def handle(conn, %{"server" => server} = _params) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, claims} <- Proxy.verify_token(token),
         rpc when is_map(rpc) <- conn.body_params do
      case Proxy.handle_rpc(server, rpc, claims) do
        {:ok, response} ->
          json(conn, response)

        {:error, err} when is_map(err) ->
          id = Map.get(rpc, "id") || Map.get(rpc, :id)

          json(conn, %{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => stringify_keys(Map.take(err, [:code, :message, :data]))
          })
      end
    else
      {:error, :missing_token} ->
        conn |> put_status(:unauthorized) |> json(%{error: "missing_token"})

      {:error, _} ->
        conn |> put_status(:unauthorized) |> json(%{error: "invalid_token"})

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_rpc"})
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_token}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v), do: v
end
