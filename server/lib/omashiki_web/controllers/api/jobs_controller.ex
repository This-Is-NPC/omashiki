defmodule OmashikiWeb.Api.JobsController do
  use OmashikiWeb, :controller

  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Admission, Api, Contract.V1, EventStream, Job}

  @max_batch_size 100
  @max_list_limit 100

  def index(conn, params) do
    with {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, jobs} <- Api.list(actor(conn), limit: limit, status: params["status"]) do
      json(conn, %{data: Enum.map(jobs, &job_json/1)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, params) do
    with {:ok, token} <- submission_token(conn),
         {:ok, job} <- Admission.admit(token, with_idempotency_header(conn, params)) do
      conn
      |> put_status(:accepted)
      |> json(%{data: job_json(job)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def batch(conn, params) do
    with {:ok, token} <- submission_token(conn),
         :ok <- batch_limit(params),
         {:ok, admitted} <- Admission.admit_batch(token, params) do
      conn
      |> put_status(:accepted)
      |> json(%{data: Enum.map(admitted, &job_json/1)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, job} <- Api.get(id, actor(conn)) do
      json(conn, %{data: job_json(job)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def result(conn, %{"id" => id}) do
    with {:ok, job} <- Api.get(id, actor(conn)),
         true <- terminal?(job) || {:error, :result_not_ready},
         attempt when not is_nil(attempt) <- Api.current_attempt(job) do
      json(conn, %{data: result_json(job, attempt)})
    else
      {:error, reason} -> error(conn, reason)
      false -> error(conn, :result_not_ready)
      nil -> error(conn, :not_found)
    end
  end

  def cancel(conn, %{"id" => id}) do
    with {:ok, job} <- Api.get(id, actor(conn)),
         {:ok, cancelled} <- Jobs.cancel(job) do
      json(conn, %{data: job_json(cancelled)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def retry(conn, %{"id" => id}) do
    with {:ok, job} <- Api.get(id, actor(conn)),
         {:ok, retried} <- Jobs.retry(job) do
      conn
      |> put_status(:accepted)
      |> json(%{data: job_json(retried)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc "Return a bounded JSON history of durable events."
  def events(conn, %{"id" => id}) do
    actor = actor(conn)

    with {:ok, %{after_sequence: after_sequence}} <- EventStream.prepare(id, actor, cursor(conn)),
         {:ok, events} <-
           EventStream.fetch_events(id, after_sequence, page_size: event_limit(conn)) do
      json(conn, %{data: Enum.map(events, &EventStream.to_map/1)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp submission_token(conn) do
    case conn.assigns[:current_token] do
      nil -> {:error, :token_required}
      token -> {:ok, token}
    end
  end

  defp batch_limit(%{"jobs" => jobs}) when is_list(jobs) and length(jobs) <= @max_batch_size,
    do: :ok

  defp batch_limit(%{"jobs" => jobs}) when is_list(jobs),
    do: {:error, {:limit, "batch_too_large", length(jobs), @max_batch_size}}

  defp batch_limit(_), do: {:error, {:validation, [%{field: "jobs", code: "required"}]}}

  defp actor(conn), do: conn.assigns[:current_token] || conn.assigns[:current_user]

  defp with_idempotency_header(conn, params) do
    case {Map.has_key?(params, "idempotency_key"), get_req_header(conn, "idempotency-key")} do
      {false, [key | _]} -> Map.put(params, "idempotency_key", key)
      _ -> params
    end
  end

  defp parse_limit(nil), do: {:ok, Api.default_limit()}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit >= 1 and limit <= @max_list_limit -> {:ok, limit}
      _ -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(_), do: {:error, :invalid_limit}

  defp event_limit(conn) do
    case get_req_header(conn, "x-events-limit") do
      [value | _] ->
        case Integer.parse(value) do
          {limit, ""} -> max(1, min(limit, 100))
          _ -> 100
        end

      _ ->
        100
    end
  end

  defp cursor(conn) do
    case get_req_header(conn, "last-event-id") do
      [] -> nil
      [value] -> value
      _ -> :invalid_cursor
    end
  end

  defp terminal?(%Job{status: status}), do: status in V1.terminal_statuses()

  defp job_json(%Job{} = job) do
    %{
      id: job.id,
      schema_version: job.schema_version,
      idempotency_key: job.idempotency_key,
      correlation_id: job.correlation_id,
      repo: job.repository,
      environment: job.environment,
      payload: job.payload,
      priority: job.priority,
      status: job.status,
      attempt: job.current_attempt,
      parent_job_id: job.parent_job_id,
      submitted_at: iso(job.inserted_at),
      queued_at: iso(job.queued_at),
      started_at: iso(job.started_at),
      finished_at: iso(job.finished_at)
    }
  end

  defp result_json(%Job{} = job, attempt) do
    %{
      job_id: job.id,
      attempt: attempt.number,
      status: job.status,
      branch: attempt.branch,
      base_sha: attempt.base_sha,
      head_sha: attempt.head_sha,
      worktree_clean: attempt.worktree_clean,
      result: attempt.result || job.terminal_result,
      error: attempt.error || job.terminal_error,
      finished_at: iso(job.finished_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp error(conn, :token_required),
    do: error_response(conn, 401, "token_required", "Bearer token required")

  defp error(conn, :unauthorized),
    do: error_response(conn, 401, "unauthorized", "Authentication failed")

  defp error(conn, :forbidden),
    do: error_response(conn, 403, "forbidden", "Job is not owned by this token")

  defp error(conn, :not_found), do: error_response(conn, 404, "not_found", "Job not found")

  defp error(conn, :invalid_limit),
    do: error_response(conn, 400, "invalid_limit", "Limit is outside the allowed range")

  defp error(conn, :invalid_status),
    do: error_response(conn, 400, "invalid_status", "Status is not supported")

  defp error(conn, :result_not_ready),
    do: error_response(conn, 409, "result_not_ready", "Job has no terminal result")

  defp error(conn, :capacity_exhausted),
    do: error_response(conn, 429, "capacity_exhausted", "Execution capacity is exhausted")

  defp error(conn, :idempotency_conflict),
    do:
      error_response(
        conn,
        409,
        "idempotency_conflict",
        "Idempotency key belongs to another token"
      )

  defp error(conn, :invalid_cursor),
    do: error_response(conn, 400, "invalid_cursor", "Last-Event-ID is invalid")

  defp error(conn, :cursor_mismatch),
    do: error_response(conn, 400, "invalid_cursor", "Last-Event-ID is for another job")

  defp error(conn, :cursor_expired),
    do: error_response(conn, 400, "invalid_cursor", "Last-Event-ID is outside retention")

  defp error(conn, :event_gap),
    do: error_response(conn, 409, "event_gap", "Durable event sequence has a gap")

  defp error(conn, {:limit, code, count, max}),
    do:
      error_response(conn, 413, code, "Request exceeds the configured limit", %{
        count: count,
        max: max
      })

  defp error(conn, {:validation, details}) do
    oversized? = Enum.any?(details, &match?(%{code: "too_large"}, &1))

    if oversized? do
      error_response(
        conn,
        413,
        "payload_too_large",
        "Payload exceeds the configured limit",
        details
      )
    else
      error_response(conn, 422, "invalid_request", "Request validation failed", details)
    end
  end

  defp error(conn, %Ecto.Changeset{}),
    do: error_response(conn, 422, "invalid_request", "Request could not be persisted")

  defp error(conn, {:invalid_transition, from, to}),
    do:
      error_response(conn, 409, "invalid_transition", "Job cannot make that transition", %{
        from: from,
        to: to
      })

  defp error(conn, :lease_required),
    do:
      error_response(
        conn,
        409,
        "lease_required",
        "Active execution must finish through its lease"
      )

  defp error(conn, :batch_parent_resolution),
    do:
      error_response(
        conn,
        422,
        "invalid_parent_reference",
        "Batch parent references could not be resolved"
      )

  # A drain-all configuration rollout is emptying the fleet. The submission is
  # not wrong and will succeed once the swap lands, so it is a 503 with a retry
  # hint rather than a 4xx that says the client did something invalid.
  defp error(conn, :admission_paused),
    do:
      error_response(
        conn,
        503,
        "admission_paused",
        "Configuration rollout is draining active work; retry shortly"
      )

  defp error(conn, :unknown_repository),
    do: error_response(conn, 422, "unknown_repository", "Repository is not registered")

  defp error(conn, :unknown_environment),
    do: error_response(conn, 422, "unknown_environment", "Environment is not registered")

  defp error(conn, :invalid_reference),
    do: error_response(conn, 422, "invalid_reference", "Repository and environment are invalid")

  defp error(conn, :idempotency_race),
    do:
      error_response(conn, 409, "idempotency_race", "Submission could not be safely deduplicated")

  defp error(conn, {:persistence, _changeset}),
    do: error_response(conn, 500, "internal_error", "Request could not be completed")

  defp error(conn, _reason),
    do: error_response(conn, 500, "internal_error", "Request could not be completed")

  defp error_response(conn, status, code, message, details \\ %{}) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end
end
