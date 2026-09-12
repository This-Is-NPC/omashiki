defmodule OmashikiWeb.Api.JobsController do
  use OmashikiWeb.Api.Controller

  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Admission, Api, EventStream, Job, Statuses}
  alias Omashiki.Maps
  alias OmashikiWeb.Api.Conn, as: ApiConn
  alias OmashikiWeb.RateLimiter

  @page_size 50
  @max_wait 60
  @wait_limit 2

  tags(["jobs"])

  operation(:index,
    summary: "List jobs",
    security: [%{"bearer" => ["read"]}],
    parameters: [
      status: [in: :query, type: :string, required: false],
      environment: [in: :query, type: :string, required: false],
      repository: [in: :query, type: :string, required: false],
      worker: [in: :query, type: :string, required: false],
      correlation_id: [in: :query, type: :string, required: false],
      since: [in: :query, type: :string, required: false],
      cursor: [in: :query, type: :string, required: false]
    ],
    responses: %{
      200 => {"Job list", "application/json", Schemas.JobListResponse},
      422 => {"Invalid", "application/problem+json", Schemas.Problem}
    }
  )

  def index(conn, params) do
    cursor = param(params, :cursor)

    with {:ok, filter} <- list_filter(params),
         {:ok, %{entries: jobs, next_cursor: next}} <-
           Api.list(ApiConn.actor(conn), filter: filter, cursor: cursor, page_size: @page_size) do
      json(conn, %{data: Enum.map(jobs, &job_json/1), next_cursor: next})
    end
  end

  operation(:create,
    summary: "Admit one job",
    security: [%{"bearer" => ["submit"]}],
    request_body: {"Job", "application/json", Schemas.JobAdmissionRequest},
    responses: %{
      202 => {"Admitted", "application/json", Schemas.JobResponse},
      422 => {"Invalid", "application/problem+json", Schemas.Problem},
      503 => {"Busy", "application/problem+json", Schemas.Problem}
    }
  )

  def create(conn, _params) do
    attrs = body(conn) |> with_idempotency_header(conn)

    with {:ok, token} <- submission_token(conn),
         {:ok, origin, job} <- Admission.admit_once(token, attrs) do
      if origin == :created, do: ApiConn.audit(conn, token, "submit", job_id: job.id)

      conn
      |> put_status(:accepted)
      |> json(%{data: job_json(job)})
    end
  end

  operation(:batch,
    summary: "Admit a batch of jobs",
    security: [%{"bearer" => ["submit"]}],
    request_body: {"Batch", "application/json", Schemas.JobBatchRequest},
    responses: %{
      202 => {"Admitted", "application/json", Schemas.JobListResponse},
      413 => {"Too large", "application/problem+json", Schemas.Problem},
      422 => {"Invalid", "application/problem+json", Schemas.Problem},
      503 => {"Busy", "application/problem+json", Schemas.Problem}
    }
  )

  def batch(conn, _params) do
    attrs = body(conn)

    with {:ok, token} <- submission_token(conn),
         {:ok, tagged} <- Admission.admit_batch_once(token, attrs) do
      Enum.each(tagged, fn
        {:created, job} -> ApiConn.audit(conn, token, "submit", job_id: job.id)
        {:existing, _job} -> :ok
      end)

      conn
      |> put_status(:accepted)
      |> json(%{data: Enum.map(tagged, fn {_origin, job} -> job_json(job) end), next_cursor: nil})
    end
  end

  operation(:show,
    summary: "Read one job",
    security: [%{"bearer" => ["read"]}],
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Job", "application/json", Schemas.JobResponse},
      404 => {"Missing", "application/problem+json", Schemas.Problem}
    }
  )

  def show(conn, params) do
    with {:ok, job} <- Api.get(param(params, :id), ApiConn.actor(conn)) do
      json(conn, %{data: job_json(job)})
    end
  end

  operation(:result,
    summary: "Read a terminal job result",
    security: [%{"bearer" => ["read"]}],
    parameters: [
      id: [in: :path, type: :string, required: true],
      wait: [
        in: :query,
        required: false,
        schema: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 60}
      ]
    ],
    responses: %{
      200 => {"Result", "application/json", Schemas.JobResultResponse},
      202 => {"Not ready", "application/problem+json", Schemas.Problem},
      409 => {"Not ready", "application/problem+json", Schemas.Problem}
    }
  )

  def result(conn, params) do
    id = param(params, :id)
    wait = param(params, :wait)

    with {:ok, job} <- Api.get(id, ApiConn.actor(conn)) do
      cond do
        Statuses.terminal?(job.status) -> render_result(conn, job)
        is_integer(wait) and wait > 0 -> wait_for_result(conn, job, min(wait, @max_wait))
        true -> {:error, :result_not_ready}
      end
    end
  end

  operation(:cancel,
    summary: "Cancel a job",
    security: [%{"bearer" => ["cancel"]}],
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Cancelled", "application/json", Schemas.JobResponse},
      503 => {"Busy", "application/problem+json", Schemas.Problem}
    }
  )

  def cancel(conn, params) do
    with {:ok, job} <- Api.get(param(params, :id), ApiConn.actor(conn)),
         {:ok, cancelled} <- Jobs.cancel(job) do
      ApiConn.audit(conn, conn.assigns[:current_token], "cancel", job_id: cancelled.id)
      json(conn, %{data: job_json(cancelled)})
    end
  end

  operation(:retry,
    summary: "Retry a failed or cancelled job",
    security: [%{"bearer" => ["submit"]}],
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      202 => {"Retried", "application/json", Schemas.JobResponse},
      503 => {"Busy", "application/problem+json", Schemas.Problem}
    }
  )

  def retry(conn, params) do
    with {:ok, job} <- Api.get(param(params, :id), ApiConn.actor(conn)),
         {:ok, retried} <- Jobs.retry(job) do
      ApiConn.audit(conn, conn.assigns[:current_token], "retry", job_id: retried.id)

      conn
      |> put_status(:accepted)
      |> json(%{data: job_json(retried)})
    end
  end

  operation(:events,
    summary: "Read durable job events",
    security: [%{"bearer" => ["read"]}],
    parameters: [
      id: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Events", "application/json", Schemas.JobEventListResponse}
    }
  )

  def events(conn, params) do
    id = param(params, :id)
    actor = ApiConn.actor(conn)

    with {:ok, %{after_sequence: after_sequence}} <- EventStream.prepare(id, actor, cursor(conn)),
         {:ok, events} <-
           EventStream.fetch_events(id, after_sequence, page_size: event_limit(conn)) do
      json(conn, %{data: Enum.map(events, &EventStream.to_map/1)})
    end
  end

  defp wait_for_result(conn, %Job{} = job, wait_s) do
    token_id = actor_token_id(conn)

    with :ok <- acquire_wait(token_id) do
      try do
        Phoenix.PubSub.subscribe(Omashiki.PubSub, "job:#{job.id}")
        deadline = System.monotonic_time(:millisecond) + wait_s * 1000
        wait_loop(conn, job.id, deadline)
      after
        Phoenix.PubSub.unsubscribe(Omashiki.PubSub, "job:#{job.id}")
        release_wait(token_id)
      end
    end
  end

  defp wait_loop(conn, job_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case Api.get(job_id, ApiConn.actor(conn)) do
      {:ok, job} ->
        if Statuses.terminal?(job.status) do
          render_result(conn, job)
        else
          if remaining <= 0 do
            Problem.send(conn, "result_not_ready", status: 202, retry_after: 1)
          else
            receive do
              {:job_updated, ^job_id} -> wait_loop(conn, job_id, deadline)
            after
              min(remaining, 1_000) -> wait_loop(conn, job_id, deadline)
            end
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp acquire_wait(nil), do: :ok

  defp acquire_wait(token_id) do
    case RateLimiter.checkout("wait", token_id, @wait_limit) do
      {:ok, _} -> :ok
      {:error, :rate_limited} -> {:error, :wait_limit}
    end
  end

  defp release_wait(nil), do: :ok
  defp release_wait(token_id), do: RateLimiter.checkin("wait", token_id)

  defp render_result(conn, %Job{} = job) do
    case Api.current_attempt(job) do
      nil -> {:error, :not_found}
      attempt -> json(conn, %{data: result_json(job, attempt)})
    end
  end

  defp submission_token(conn) do
    case conn.assigns[:current_token] do
      nil -> {:error, :token_required}
      token -> {:ok, token}
    end
  end

  defp actor_token_id(conn), do: conn.assigns[:current_token] && conn.assigns.current_token.id

  defp body(conn), do: Maps.stringify_keys(conn.body_params)

  defp param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp with_idempotency_header(params, conn) do
    case {Map.has_key?(params, "idempotency_key"), get_req_header(conn, "idempotency-key")} do
      {false, [key | _]} -> Map.put(params, "idempotency_key", key)
      _ -> params
    end
  end

  defp list_filter(params) do
    filter =
      %{}
      |> maybe_put_filter(:status, param(params, :status))
      |> maybe_put_filter(:environment, param(params, :environment))
      |> maybe_put_filter(:repository, param(params, :repository))
      |> maybe_put_filter(:worker, param(params, :worker))
      |> maybe_put_filter(:correlation_id, param(params, :correlation_id))

    put_since(filter, param(params, :since))
  end

  defp maybe_put_filter(filter, _key, nil), do: filter
  defp maybe_put_filter(filter, _key, ""), do: filter
  defp maybe_put_filter(filter, key, value), do: Map.put(filter, key, value)

  defp put_since(filter, nil), do: {:ok, filter}

  defp put_since(filter, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, Map.put(filter, :since, dt)}
      _ -> {:error, {:validation, [%{field: "since", code: "invalid"}]}}
    end
  end

  defp put_since(_filter, _), do: {:error, {:validation, [%{field: "since", code: "invalid"}]}}

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

  defp cursor(conn), do: ApiConn.last_event_id(conn)

  defp job_json(%Job{} = job) do
    %{
      id: job.id,
      idempotency_key: job.idempotency_key,
      correlation_id: job.correlation_id,
      repo: job.repository,
      environment: job.environment,
      payload: job.payload,
      priority: job.priority,
      status: job.status,
      attempt: job.current_attempt,
      depends_on: depends_on_ids(job),
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
      summary: attempt.summary,
      changes: attempt.changes,
      compare_url: attempt.compare_url,
      result: attempt.result || job.terminal_result,
      error: attempt.error || job.terminal_error,
      finished_at: iso(job.finished_at)
    }
  end

  defp depends_on_ids(%Job{id: job_id}) do
    alias Omashiki.Jobs.JobDependency
    import Ecto.Query

    from(d in JobDependency, where: d.job_id == ^job_id, select: d.depends_on_job_id)
    |> Omashiki.Repo.all()
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
