defmodule OmashikiWeb.Api.Problem do
  @moduledoc """
  RFC 9457 problem+json renderer for the public and worker HTTP APIs.

  Every API error goes through this module. Controllers do not render error
  bodies themselves.
  """

  import Plug.Conn

  require Logger

  @codes ~w(
    missing_token
    token_required
    unauthorized
    invalid_credentials
    invalid_token
    token_expired
    insufficient_scope
    forbidden
    not_found
    invalid_status
    invalid_cursor
    result_not_ready
    capacity_exhausted
    rate_limited
    max_active_jobs
    wait_limit
    idempotency_conflict
    event_gap
    batch_too_large
    payload_too_large
    invalid_request
    invalid_transition
    lease_required
    invalid_parent_reference
    admission_paused
    busy
    unknown_repository
    unknown_environment
    invalid_reference
    idempotency_race
    environment_not_allowed
    already_delivered
    signup_closed
    auth_mode_none_loopback_only
    invalid_capacity
    invalid_containers
    missing_digest
    digest_mismatch
    invalid_complete
    invalid_free_slots
    blob_missing
    stale_lease
    lease_expired
    attempt_not_active
    already_running
    invalid_success_result
    task_branch_required
    internal_error
  )

  @titles %{
    "missing_token" => "Bearer token required",
    "token_required" => "Bearer token required",
    "unauthorized" => "Authentication failed",
    "invalid_credentials" => "Credentials are not valid",
    "invalid_token" => "Bearer token is not valid",
    "token_expired" => "Bearer token has expired",
    "insufficient_scope" => "Token scope is insufficient",
    "forbidden" => "Job is not owned by this token",
    "not_found" => "Resource not found",
    "invalid_status" => "Status is not supported",
    "invalid_cursor" => "Cursor is invalid",
    "result_not_ready" => "Job has no terminal result",
    "capacity_exhausted" => "Execution capacity is exhausted",
    "rate_limited" => "Request rate limit exceeded",
    "max_active_jobs" => "Token active-job limit exceeded",
    "wait_limit" => "Too many concurrent result waits",
    "idempotency_conflict" => "Idempotency key belongs to another token",
    "event_gap" => "Durable event sequence has a gap",
    "batch_too_large" => "Batch exceeds the configured limit",
    "payload_too_large" => "Payload exceeds the configured limit",
    "invalid_request" => "Request validation failed",
    "invalid_transition" => "Job cannot make that transition",
    "lease_required" => "Active execution must finish through its lease",
    "invalid_parent_reference" => "Batch parent references could not be resolved",
    "admission_paused" => "Configuration rollout is draining active work",
    "busy" => "The server could not complete the request without a lock conflict",
    "unknown_repository" => "Repository is not registered",
    "unknown_environment" => "Environment is not registered",
    "invalid_reference" => "Repository and environment are invalid",
    "idempotency_race" => "Submission could not be safely deduplicated",
    "environment_not_allowed" => "Environment is not allowed for this token",
    "already_delivered" => "Delivered webhook cannot be redelivered",
    "signup_closed" => "Operator already exists",
    "auth_mode_none_loopback_only" => "Local auth is only valid on loopback",
    "invalid_capacity" => "capacity must be a non-negative integer",
    "invalid_containers" => "containers must be a valid report list",
    "missing_digest" => "x-omashiki-digest header is required",
    "digest_mismatch" => "Digest does not match request body",
    "invalid_complete" => "Complete payload is required",
    "invalid_free_slots" => "free_slots must be a non-negative integer",
    "blob_missing" => "Blob was not uploaded for this job",
    "stale_lease" => "Lease token is no longer valid",
    "lease_expired" => "Lease has expired",
    "attempt_not_active" => "Attempt is not active",
    "already_running" => "Attempt is already running",
    "invalid_success_result" => "Success payload is invalid",
    "task_branch_required" => "Git sink requires payload.branch or payload.title",
    "internal_error" => "Request could not be completed"
  }

  @http_status %{
    "missing_token" => 401,
    "token_required" => 401,
    "unauthorized" => 401,
    "invalid_credentials" => 401,
    "invalid_token" => 403,
    "token_expired" => 401,
    "insufficient_scope" => 403,
    "forbidden" => 403,
    "not_found" => 404,
    "invalid_status" => 400,
    "invalid_cursor" => 400,
    "result_not_ready" => 409,
    "capacity_exhausted" => 429,
    "rate_limited" => 429,
    "max_active_jobs" => 429,
    "wait_limit" => 429,
    "idempotency_conflict" => 409,
    "event_gap" => 409,
    "batch_too_large" => 413,
    "payload_too_large" => 413,
    "invalid_request" => 422,
    "invalid_transition" => 409,
    "lease_required" => 409,
    "invalid_parent_reference" => 422,
    "admission_paused" => 503,
    "busy" => 503,
    "unknown_repository" => 422,
    "unknown_environment" => 422,
    "invalid_reference" => 422,
    "idempotency_race" => 409,
    "environment_not_allowed" => 422,
    "already_delivered" => 409,
    "signup_closed" => 409,
    "auth_mode_none_loopback_only" => 401,
    "invalid_capacity" => 422,
    "invalid_containers" => 422,
    "missing_digest" => 400,
    "digest_mismatch" => 400,
    "invalid_complete" => 422,
    "invalid_free_slots" => 422,
    "blob_missing" => 409,
    "stale_lease" => 409,
    "lease_expired" => 409,
    "attempt_not_active" => 409,
    "already_running" => 409,
    "invalid_success_result" => 422,
    "task_branch_required" => 422,
    "internal_error" => 500
  }

  def codes, do: @codes
  def known_code?(code) when is_binary(code), do: code in @codes

  def status_for(code) when is_binary(code), do: Map.fetch!(@http_status, code)

  def body(conn, code, opts \\ []) when is_binary(code) do
    unless known_code?(code), do: raise(ArgumentError, "unknown problem code: #{code}")

    status = Keyword.get(opts, :status, status_for(code))
    title = Keyword.get(opts, :title, Map.fetch!(@titles, code))
    detail = Keyword.get(opts, :detail, title)
    errors = Keyword.get(opts, :errors)
    extra = Keyword.get(opts, :errors_extra)
    request_id = request_id(conn)

    %{
      type: "about:blank",
      title: title,
      status: status,
      code: code,
      detail: detail,
      errors: normalize_errors(errors, extra),
      request_id: request_id
    }
  end

  def send(conn, code, opts \\ []) when is_binary(code) do
    payload = body(conn, code, opts)
    status = payload.status
    request_id = payload.request_id

    Logger.info("api_error code=#{code} status=#{status} request_id=#{request_id}")

    conn =
      conn
      |> put_resp_content_type("application/problem+json")
      |> put_status(status)

    conn =
      case Keyword.get(opts, :retry_after) do
        nil -> conn
        seconds -> put_resp_header(conn, "retry-after", Integer.to_string(seconds))
      end

    Phoenix.Controller.json(conn, payload)
  end

  def halt(conn, code, opts \\ []) do
    conn
    |> send(code, opts)
    |> halt()
  end

  def from_reason(conn, reason), do: send(conn, code_for(reason), opts_for(reason))

  def code_for(reason) do
    case reason do
      :missing_token ->
        "missing_token"

      :token_required ->
        "token_required"

      :unauthorized ->
        "unauthorized"

      :invalid_credentials ->
        "invalid_credentials"

      :invalid_token ->
        "invalid_token"

      :token_expired ->
        "token_expired"

      :insufficient_scope ->
        "insufficient_scope"

      :forbidden ->
        "forbidden"

      :not_found ->
        "not_found"

      :invalid_status ->
        "invalid_status"

      :invalid_cursor ->
        "invalid_cursor"

      :cursor_mismatch ->
        "invalid_cursor"

      :cursor_expired ->
        "invalid_cursor"

      :result_not_ready ->
        "result_not_ready"

      :capacity_exhausted ->
        "capacity_exhausted"

      :rate_limited ->
        "rate_limited"

      :max_active_jobs ->
        "max_active_jobs"

      :wait_limit ->
        "wait_limit"

      :idempotency_conflict ->
        "idempotency_conflict"

      :event_gap ->
        "event_gap"

      :invalid_request ->
        "invalid_request"

      :admission_paused ->
        "admission_paused"

      :busy ->
        "busy"

      :unknown_repository ->
        "unknown_repository"

      :unknown_environment ->
        "unknown_environment"

      :invalid_reference ->
        "invalid_reference"

      :idempotency_race ->
        "idempotency_race"

      :environment_not_allowed ->
        "environment_not_allowed"

      :already_delivered ->
        "already_delivered"

      :signup_closed ->
        "signup_closed"

      :lease_required ->
        "lease_required"

      :batch_parent_resolution ->
        "invalid_parent_reference"

      :invalid_capacity ->
        "invalid_capacity"

      :invalid_containers ->
        "invalid_containers"

      :missing_digest ->
        "missing_digest"

      :digest_mismatch ->
        "digest_mismatch"

      :invalid_complete ->
        "invalid_complete"

      :invalid_free_slots ->
        "invalid_free_slots"

      :blob_missing ->
        "blob_missing"

      :stale_lease ->
        "stale_lease"

      :lease_expired ->
        "lease_expired"

      :attempt_not_active ->
        "attempt_not_active"

      :already_running ->
        "already_running"

      :invalid_success_result ->
        "invalid_success_result"

      :task_branch_required ->
        "task_branch_required"

      {:limit, "batch_too_large", _, _} ->
        "batch_too_large"

      {:limit, code, _, _} when is_binary(code) ->
        code

      {:validation, details} ->
        if oversized?(details), do: "payload_too_large", else: "invalid_request"

      {:invalid_transition, _, _} ->
        "invalid_transition"

      %Ecto.Changeset{} ->
        "invalid_request"

      {:persistence, _} ->
        "internal_error"

      _ ->
        "internal_error"
    end
  end

  def opts_for(reason) do
    case reason do
      {:limit, _code, count, max} ->
        [errors_extra: %{count: count, max: max}]

      {:validation, details} when is_list(details) ->
        [errors: details]

      {:validation, field} when is_binary(field) ->
        [errors: [%{field: field, code: "required"}]]

      {:invalid_transition, from, to} ->
        [errors_extra: %{from: from, to: to}]

      %Ecto.Changeset{} = changeset ->
        [errors: changeset_errors(changeset)]

      :rate_limited ->
        [retry_after: 60]

      :max_active_jobs ->
        [retry_after: 30]

      :wait_limit ->
        [retry_after: 5]

      :capacity_exhausted ->
        [retry_after: 5]

      :admission_paused ->
        [retry_after: 5]

      :busy ->
        [retry_after: 1]

      _ ->
        []
    end
  end

  def request_id(conn) do
    conn
    |> get_resp_header("x-request-id")
    |> List.first()
    |> case do
      nil -> Logger.metadata()[:request_id]
      value -> value
    end
  end

  defp normalize_errors(nil, nil), do: []
  defp normalize_errors(nil, extra) when is_map(extra), do: [extra]

  defp normalize_errors(errors, extra) when is_list(errors) do
    errors = Enum.map(errors, &error_item/1)
    if is_map(extra), do: errors ++ [extra], else: errors
  end

  defp normalize_errors(errors, extra) when is_map(errors) do
    normalize_errors([errors], extra)
  end

  defp error_item(%{field: field, code: code}),
    do: %{field: to_string(field), code: to_string(code)}

  defp error_item(%{"field" => field, "code" => code}), do: %{field: field, code: code}
  defp error_item(other) when is_map(other), do: other

  defp oversized?(details) when is_list(details),
    do: Enum.any?(details, &match?(%{code: "too_large"}, &1))

  defp oversized?(_), do: false

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map(fn {field, messages} ->
      %{field: to_string(field), code: "invalid", detail: List.first(messages)}
    end)
  end
end
