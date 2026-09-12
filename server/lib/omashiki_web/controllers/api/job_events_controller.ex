defmodule OmashikiWeb.Api.JobEventsController do
  use OmashikiWeb.Api.Controller

  alias Omashiki.Jobs.EventStream
  alias OmashikiWeb.Api.Conn, as: ApiConn

  tags(["jobs"])

  operation(:stream,
    summary: "Stream job events as SSE",
    security: [%{"bearer" => ["read"]}],
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 =>
        {"Event stream", "text/event-stream",
         %OpenApiSpex.Schema{type: :string, description: "Server-sent events"}},
      422 => {"Invalid cursor", "application/problem+json", Schemas.Problem}
    }
  )

  def stream(conn, params) do
    job_id = Map.get(params, :id) || Map.get(params, "id")
    actor = ApiConn.actor(conn)

    case EventStream.prepare(job_id, actor, ApiConn.last_event_id(conn)) do
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
end
