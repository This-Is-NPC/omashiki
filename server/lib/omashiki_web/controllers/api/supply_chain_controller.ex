defmodule OmashikiWeb.Api.SupplyChainController do
  @moduledoc "HTTP controller for job-bound npm, Cargo, and Go proxy traffic."

  use OmashikiWeb, :controller

  alias Omashiki.SupplyChain.Proxy

  def package(
        conn,
        %{
          "cache_group" => _cache_group,
          "ecosystem" => ecosystem,
          "proxy_token" => token
        } = params
      ) do
    conn = fetch_query_params(conn)
    path = "/#{ecosystem}/" <> Enum.join(Map.get(params, "path", []), "/")

    with {:ok, claims} <- Proxy.verify_token(token),
         true <- claims["cache_group"] == params["cache_group"],
         {:ok, response} <-
           Proxy.handle_request(
             conn.method,
             path <> query_string(conn),
             request_headers(conn),
             claims,
             token: token,
             base_url: request_base_url(conn)
           ) do
      send_proxy_response(conn, response)
    else
      {:error, %{status: status, message: message}} ->
        conn |> put_status(status) |> json(%{error: message})

      {:error, reason} when reason in [:invalid, :expired] ->
        conn |> put_status(:unauthorized) |> json(%{error: "invalid_token"})

      false ->
        conn |> put_status(:forbidden) |> json(%{error: "cache_group_mismatch"})

      {:error, reason} ->
        conn |> put_status(502) |> json(%{error: "supply_chain_proxy", reason: inspect(reason)})
    end
  end

  defp send_proxy_response(conn, %{status: status, headers: headers, body: body}) do
    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc ->
        if String.downcase(key) in ["content-type", "cache-control", "etag", "last-modified"] do
          put_resp_header(acc, String.downcase(key), value)
        else
          acc
        end
      end)

    body = if conn.method == "HEAD", do: "", else: body
    send_resp(conn, status, body)
  end

  defp request_headers(conn) do
    Enum.map(conn.req_headers, fn {key, value} -> {key, value} end)
  end

  defp query_string(%Plug.Conn{query_string: ""}), do: ""
  defp query_string(%Plug.Conn{query_string: query}), do: "?" <> query

  defp request_base_url(conn) do
    default_port = if conn.scheme == :https, do: 443, else: 80
    port = if conn.port == default_port, do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port}"
  end
end
