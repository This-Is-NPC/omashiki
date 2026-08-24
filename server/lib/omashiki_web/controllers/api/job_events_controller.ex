defmodule OmashikiWeb.Api.JobEventsController do
  use OmashikiWeb, :controller

  alias Omashiki.Jobs.EventStream

  @doc "Stream only persisted events for the authenticated job client."
  def stream(conn, %{"id" => job_id}) do
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
        error_response(conn, reason)
    end
  end

  defp last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [] -> nil
      [value] -> value
      _ -> :invalid_cursor
    end
  end

  defp error_response(conn, :not_found), do: json_error(conn, 404, "not_found")
  defp error_response(conn, :forbidden), do: json_error(conn, 403, "forbidden")

  defp error_response(conn, reason)
       when reason in ~w(invalid_cursor cursor_mismatch cursor_expired)a,
       do: json_error(conn, 400, "invalid_cursor")

  defp json_error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message_for(code), details: %{}}})
  end

  defp message_for("not_found"), do: "Job not found"
  defp message_for("forbidden"), do: "Job is not owned by this token"
  defp message_for("invalid_cursor"), do: "Last-Event-ID is invalid"
end
