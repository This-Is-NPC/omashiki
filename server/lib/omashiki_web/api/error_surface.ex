defmodule OmashikiWeb.Api.ErrorSurface do
  @moduledoc """
  Problem codes each public operation can return.

  Plug codes come from the pipeline that actually calls `Problem.halt/2`.
  Action codes come from `{:error, reason}` tuples that `FallbackController`
  maps through `Problem.code_for/1`. Statuses are always `Problem.status_for/1`.
  """

  alias OmashikiWeb.Api.Problem

  @bearer_plug_codes ~w(
    missing_token
    unauthorized
    invalid_token
    token_expired
    insufficient_scope
    rate_limited
    auth_mode_none_loopback_only
  )

  @action_codes %{
    {"/api/v1/jobs", "get"} => ~w(invalid_status invalid_cursor),
    {"/api/v1/jobs", "post"} =>
      ~w(invalid_request admission_paused busy max_active_jobs unknown_repository unknown_environment invalid_reference environment_not_allowed idempotency_conflict idempotency_race task_branch_required payload_too_large),
    {"/api/v1/jobs/batch", "post"} =>
      ~w(invalid_request admission_paused busy max_active_jobs batch_too_large invalid_parent_reference),
    {"/api/v1/jobs/{id}/retry", "post"} =>
      ~w(not_found busy max_active_jobs invalid_transition lease_required),
    {"/api/v1/jobs/{id}/cancel", "post"} => ~w(not_found busy invalid_transition),
    {"/api/v1/jobs/{id}/result", "get"} => ~w(not_found result_not_ready wait_limit),
    {"/api/v1/jobs/{id}/events", "get"} => ~w(not_found forbidden invalid_cursor event_gap),
    {"/api/v1/jobs/{id}/events/history", "get"} => ~w(not_found forbidden invalid_cursor),
    {"/api/v1/jobs/{id}/webhook-deliveries/{delivery_id}/redeliver", "post"} =>
      ~w(not_found busy already_delivered),
    {"/api/v1/sessions/issue_token", "post"} =>
      ~w(invalid_credentials rate_limited invalid_request),
    {"/api/v1/sessions/signup", "post"} => ~w(signup_closed invalid_request)
  }

  def bearer_plug_codes, do: @bearer_plug_codes

  def action_codes(path, method), do: Map.get(@action_codes, {path, method}, [])

  def codes(path, method, bearer?) do
    plugs = if bearer?, do: @bearer_plug_codes, else: []
    Enum.uniq(plugs ++ action_codes(path, method))
  end

  def required_statuses(path, method, bearer?) do
    path
    |> codes(method, bearer?)
    |> Enum.map(&Problem.status_for/1)
    |> Enum.uniq()
  end
end
