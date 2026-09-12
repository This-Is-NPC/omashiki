defmodule OmashikiWeb.Api.JobEventsController do
  use OmashikiWeb.Api.Controller

  alias Omashiki.Jobs.EventStream

  tags ["jobs"]

  operation :stream,
    summary: "Stream job events as SSE",
    security: [%{"bearer" => ["read"]}],
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 =>
        {"Event stream", "text/event-stream",
         %OpenApiSpex.Schema{type: :string, description: "Server-sent events"}}
    }

  def stream(conn, params) do
    job_id = Map.get(params, :id) || Map.get(params, "id")
    actor = conn.assigns[:current_token] || conn.assigns[:current_user]

    case EventStream.prepare(job_id, actor, last_event_id(conn)) do
      {:ok, %{job: job, after_sequence: after_sequence}} ->
        conn
        |> put_resp_header("cache-control", "no-cache, no-store")
        |> put_resp_header("connection", "keep-alive")
        |> put_resp_header("x-accel-buffering", "no")
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)
        |> EventStream.stream(job, after_sequence)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [] -> nil
      [value] -> value
      _ -> :invalid_cursor
    end
  end
end
