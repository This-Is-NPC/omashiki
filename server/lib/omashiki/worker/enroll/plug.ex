defmodule Omashiki.Worker.Enroll.Plug do
  @moduledoc false

  import Plug.Conn

  alias Omashiki.Worker.Enroll

  use Plug.Router

  plug Plug.Logger
  plug :match
  plug :dispatch

  get "/healthz" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{role: "worker", status: "ok"}))
  end

  post "/internal/enroll" do
    conn
    |> authenticate()
    |> enroll()
  end

  match _ do
    send_error(conn, 404, "not_found", "Route not found")
  end

  defp authenticate(conn) do
    cond do
      not Enroll.secret_configured?() ->
        send_error(conn, 403, "enroll_disabled", "Worker enrollment is disabled")

      is_nil(extract_bearer(conn)) ->
        send_error(conn, 401, "missing_token", "Enroll bearer token required")

      Enroll.valid_secret?(extract_bearer(conn)) ->
        conn

      true ->
        send_error(conn, 403, "invalid_token", "Enroll bearer token is not valid")
    end
  end

  defp enroll(%Plug.Conn{state: :sent} = conn), do: conn

  defp enroll(conn) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, decoded} <- Jason.decode(body),
         :ok <- Enroll.enroll(decoded) do
      conn |> send_resp(204, "") |> halt()
    else
      {:error, :invalid_body} ->
        send_error(conn, 422, "invalid_body", "manager_url and worker_token are required")

      _ ->
        send_error(conn, 422, "invalid_body", "manager_url and worker_token are required")
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp send_error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{code: code, message: message}}))
    |> halt()
  end
end
