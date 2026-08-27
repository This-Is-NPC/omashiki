defmodule Omashiki.Jobs.Contract.V1Test do
  use ExUnit.Case, async: true

  alias Omashiki.Jobs.Contract.V1

  @job_id "8e55e53c-7f9a-4e56-8f97-92d56cf37ad8"
  @parent_job_id "7b66de31-3315-4f42-8ad3-5cae493cda3e"
  @event_id "e93a1cad-a329-46a1-a804-bc947779870a"
  @sha String.duplicate("a", 40)

  test "exposes stable version and execution semantics" do
    assert V1.version() == 1
    assert V1.max_payload_bytes() == 1_048_576
    assert V1.semantics().batch_admission == :atomic
    assert V1.semantics().payload_limit_scope == :per_job_json_encoded
    assert V1.semantics().dependency_scope == :same_batch
    assert V1.semantics().dependency_failure_effect == :edge_policy
    assert V1.semantics().dependency_success_effect == :unlock_when_all_succeeded
    assert V1.semantics().retry_identity == :same_job_new_attempt
    assert V1.semantics().timeout_outcome == :failed
    assert V1.semantics().webhook_delivery == :at_least_once
  end

  test "validates a single job envelope" do
    request = single_request()
    assert {:ok, ^request} = V1.validate_single(request)
  end

  test "rejects missing, unknown, and invalid single job fields" do
    assert {:error, errors} =
             single_request()
             |> Map.put("parent_ref", "legacy")
             |> Map.put("priority", 4)
             |> Map.put("schema_version", 2)
             |> V1.validate_single()

    assert {:ok, _} = V1.validate_single(single_request() |> Map.delete("repo"))
    assert_error(errors, "parent_ref", "unknown_field")
    assert_error(errors, "priority", "must_be_between_0_and_3")
    assert_error(errors, "schema_version", "unsupported")
  end

  test "enforces the encoded payload limit" do
    exact_payload = %{"instruction" => String.duplicate("x", V1.max_payload_bytes() - 32)}
    oversized_payload = %{"instruction" => String.duplicate("x", V1.max_payload_bytes() + 1)}

    assert {:ok, _} = V1.validate_single(single_request(exact_payload))
    assert {:error, errors} = V1.validate_single(single_request(oversized_payload))
    assert_error(errors, "payload.instruction", "too_large")
  end

  test "rejects non-JSON payload values" do
    assert {:error, errors} = V1.validate_single(single_request(%{atom_key: :atom_value}))
    assert_error(errors, "payload.instruction", "required")
    assert_error(errors, "payload.atom_key", "unknown_field")
  end

  test "rejects malformed single depends_on entries at contract validation" do
    assert {:error, errors} =
             single_request()
             |> Map.put("depends_on", ["not-an-object"])
             |> V1.validate_single()

    assert_error(errors, "depends_on", "object_required")

    assert {:error, on_failure_errors} =
             single_request()
             |> Map.put("depends_on", [%{"id" => @parent_job_id, "on_failure" => "explode"}])
             |> V1.validate_single()

    assert_error(on_failure_errors, "depends_on.on_failure", "unsupported")
  end

  test "accepts well-formed single depends_on entries" do
    request =
      single_request()
      |> Map.put("depends_on", [%{"id" => @parent_job_id, "on_failure" => "block"}])

    assert {:ok, ^request} = V1.validate_single(request)
  end

  test "validates an atomic same-batch parent chain" do
    batch = %{
      "schema_version" => 1,
      "correlation_id" => "workflow-42",
      "jobs" => [
        batch_job("root"),
        batch_job("child", [%{"ref" => "root"}]),
        batch_job("grandchild", [%{"ref" => "child"}])
      ]
    }

    assert {:ok, ^batch} = V1.validate_batch(batch)
  end

  test "rejects parent references outside the batch" do
    batch = %{"schema_version" => 1, "jobs" => [batch_job("child", [%{"ref" => "external-job"}])]}

    assert {:error, errors} = V1.validate_batch(batch)
    assert_error(errors, "jobs.depends_on", "unknown_ref")
  end

  test "rejects self-parenting and cycles" do
    self_parent = %{"schema_version" => 1, "jobs" => [batch_job("a", [%{"ref" => "a"}])]}

    cycle = %{
      "schema_version" => 1,
      "jobs" => [batch_job("a", [%{"ref" => "b"}]), batch_job("b", [%{"ref" => "a"}])]
    }

    assert {:error, self_errors} = V1.validate_batch(self_parent)
    assert_error(self_errors, "jobs.depends_on", "self_dependency")
    assert_error(self_errors, "jobs.depends_on", "cycle")

    assert {:error, cycle_errors} = V1.validate_batch(cycle)
    assert_error(cycle_errors, "jobs.depends_on", "cycle")
  end

  test "rejects duplicate refs and idempotency keys" do
    duplicate = %{
      "schema_version" => 1,
      "jobs" => [batch_job("a"), batch_job("a")]
    }

    assert {:error, errors} = V1.validate_batch(duplicate)
    assert_error(errors, "jobs.ref", "duplicate")
    assert_error(errors, "jobs.idempotency_key", "duplicate")
  end

  test "rejects malformed batch members without raising" do
    assert {:error, errors} =
             V1.validate_batch(%{
               "schema_version" => 1,
               "correlation_id" => "workflow-42",
               "jobs" => [nil]
             })

    assert_error(errors, "jobs.0", "object_required")
  end

  test "validates single and atomic batch admission responses" do
    root = admission_response("queued", [], @parent_job_id)
    child = admission_response("blocked", [@parent_job_id], @job_id)
    batch = %{"schema_version" => 1, "correlation_id" => "workflow-42", "jobs" => [root, child]}

    assert {:ok, ^root} = V1.validate_single_response(root)
    assert {:ok, ^batch} = V1.validate_batch_response(batch)
  end

  test "batch admission rejects parent IDs outside the admitted batch" do
    root = admission_response("queued", [], @parent_job_id)
    child = admission_response("blocked", [@event_id], @job_id)
    batch = %{"schema_version" => 1, "correlation_id" => "workflow-42", "jobs" => [root, child]}

    assert {:error, errors} = V1.validate_batch_response(batch)
    assert_error(errors, "jobs.depends_on", "unknown_job_id")
  end

  test "admission response status reflects parent presence" do
    assert {:error, blocked_errors} =
             "blocked" |> admission_response() |> V1.validate_single_response()

    assert_error(blocked_errors, "depends_on", "required_when_blocked")

    assert {:error, queued_errors} =
             admission_response("queued", [@event_id]) |> V1.validate_single_response()

    assert_error(queued_errors, "depends_on", "not_allowed_when_queued")
  end

  test "retry eligibility is limited to unsuccessful terminal states" do
    assert V1.retry_allowed?("failed")
    assert V1.retry_allowed?("cancelled")
    refute V1.retry_allowed?("succeeded")
  end

  test "validates operation-aware transitions and attempt identity" do
    assert {:ok, _} = V1.validate_transition(transition("advance", "queued", "running"))
    assert {:ok, _} = V1.validate_transition(transition("cancel", "running", "cancelled"))
    assert {:ok, _} = V1.validate_transition(transition("timeout", "running", "failed"))

    retry = transition("retry", "failed", "queued", 2, 3)
    assert {:ok, ^retry} = V1.validate_transition(retry)

    unlock =
      transition("dependency_satisfied", "blocked", "queued")
      |> Map.put("depends_on", [@parent_job_id])
      
      |> Map.put("unlock_event_id", @event_id)

    assert {:ok, ^unlock} = V1.validate_transition(unlock)
  end

  test "parent unlock transitions are bound and cannot be replayed" do
    unlock =
      transition("dependency_satisfied", "blocked", "queued")
      |> Map.put("depends_on", [@parent_job_id])
      
      |> Map.put("unlock_event_id", @event_id)

    assert {:error, errors} = V1.validate_transition_stream([unlock, unlock])
    assert_error(errors, "transitions.unlock_event_id", "duplicate")
    assert_error(errors, "transitions.dependency_unlock", "duplicate")

    assert {:error, self_errors} =
             unlock
             |> Map.put("depends_on", [@job_id])
             |> V1.validate_transition()

    assert_error(self_errors, "$", "invalid_transition")
  end

  test "rejects every unrecognized state pair and invalid retry attempt" do
    for from <- V1.statuses(), to <- V1.statuses() do
      transition = transition("advance", from, to)

      expected =
        {from, to} in [{"queued", "running"}, {"running", "succeeded"}, {"running", "failed"}]

      assert match?({:ok, _}, V1.validate_transition(transition)) == expected
    end

    assert {:error, errors} =
             "retry" |> transition("failed", "queued", 2, 2) |> V1.validate_transition()

    assert_error(errors, "$", "invalid_transition")
  end

  test "validates successful committed-branch results" do
    result = successful_result()
    assert {:ok, ^result} = V1.validate_result(result)
  end

  test "requires a clean Git artifact shape on success" do
    assert {:error, errors} =
             successful_result()
             |> Map.delete("head_sha")
             |> Map.put("worktree_clean", false)
             |> Map.put("error", error_object())
             |> V1.validate_result()

    assert_error(errors, "head_sha", "required")
    assert_error(errors, "worktree_clean", "incoherent_git_shape")
    assert_error(errors, "error", "not_allowed")
  end

  test "accepts succeeded results without git fields" do
    result =
      successful_result()
      |> Map.drop(["branch", "base_sha", "head_sha", "worktree_clean"])

    assert {:ok, ^result} = V1.validate_result(result)
  end

  test "requires structured error and forbids result artifacts on failure" do
    failed = %{
      "schema_version" => 1,
      "job_id" => @job_id,
      "attempt" => 2,
      "status" => "failed",
      "result" => %{},
      "finished_at" => "2026-08-24T03:00:00Z"
    }

    assert {:error, errors} = V1.validate_result(failed)
    assert_error(errors, "error", "required")
    assert_error(errors, "result", "not_allowed")
  end

  test "requires UTC RFC3339 timestamps" do
    assert {:error, errors} =
             successful_result()
             |> Map.put("finished_at", "2026-08-24T03:00:00+01:00")
             |> V1.validate_result()

    assert_error(errors, "finished_at", "utc_rfc3339_required")
  end

  test "validates ordered attempt-aware events" do
    event = terminal_event()
    assert {:ok, ^event} = V1.validate_event(event)
  end

  test "event type must match projected status" do
    assert {:error, errors} =
             terminal_event()
             |> Map.put("status", "failed")
             |> V1.validate_event()

    assert_error(errors, "status", "does_not_match_event_type")
  end

  test "observable event data rejects sensitive contract content" do
    assert {:error, errors} =
             terminal_event()
             |> Map.put("data", %{"nested" => %{"authorization" => "Bearer secret"}})
             |> V1.validate_event()

    assert_error(errors, "data", "unobservable_field")
  end

  test "observable event data rejects malformed and nested values without raising" do
    assert {:error, atom_errors} =
             terminal_event()
             |> Map.put("data", %{api_key: "secret"})
             |> V1.validate_event()

    assert_error(atom_errors, "data", "unobservable_field")

    assert {:error, nested_errors} =
             terminal_event()
             |> Map.put("data", %{"branch" => %{"secret" => "value"}})
             |> V1.validate_event()

    assert_error(nested_errors, "data.branch", "string_required")
  end

  test "invalid UTF-8 is rejected without raising" do
    invalid_utf8 = <<255>>

    assert {:error, request_errors} =
             single_request()
             |> Map.put("repo", invalid_utf8)
             |> V1.validate_single()

    assert_error(request_errors, "repo", "utf8_required")

    assert {:error, event_errors} =
             terminal_event()
             |> Map.put("data", %{"branch" => invalid_utf8})
             |> V1.validate_event()

    assert_error(event_errors, "data", "invalid_json_value")
  end

  test "event streams enforce order and one terminal identity per attempt" do
    queued =
      terminal_event()
      |> Map.merge(%{
        "event_id" => "44e14c91-740e-494c-b0f7-eaa2a05b689e",
        "sequence" => 1,
        "type" => "job.queued",
        "status" => "queued",
        "data" => %{"retry" => false}
      })

    running =
      terminal_event()
      |> Map.merge(%{
        "event_id" => "d879b484-b5d9-48a2-bfa1-e1975c448ba1",
        "sequence" => 2,
        "type" => "job.running",
        "status" => "running",
        "data" => %{"environment" => "opencode"}
      })

    terminal = terminal_event() |> Map.put("sequence", 3)

    assert {:ok, [^queued, ^running, ^terminal]} =
             V1.validate_event_stream([queued, running, terminal])

    duplicate_terminal =
      terminal
      |> Map.put("event_id", "5fdb4936-96f2-4934-af09-e2862d625940")
      |> Map.put("sequence", 4)

    assert {:error, errors} =
             V1.validate_event_stream([queued, running, terminal, duplicate_terminal])

    assert_error(errors, "events", "multiple_terminal_outcomes_per_attempt")
  end

  test "event streams reject illegal histories and huge attempt gaps safely" do
    queued =
      terminal_event()
      |> Map.merge(%{
        "event_id" => "44e14c91-740e-494c-b0f7-eaa2a05b689e",
        "sequence" => 1,
        "type" => "job.queued",
        "status" => "queued",
        "data" => %{}
      })

    terminal = terminal_event() |> Map.put("sequence", 2)

    after_terminal =
      queued
      |> Map.put("event_id", "d879b484-b5d9-48a2-bfa1-e1975c448ba1")
      |> Map.put("sequence", 3)
      |> Map.put("type", "job.running")
      |> Map.put("status", "running")
      |> Map.put("data", %{"environment" => "opencode"})

    assert {:error, history_errors} =
             V1.validate_event_stream([queued, terminal, after_terminal])

    assert_error(history_errors, "events.status", "invalid_history")

    huge_attempt = queued |> Map.put("attempt", 1_000_000_000) |> Map.put("sequence", 4)
    assert {:error, attempt_errors} = V1.validate_event_stream([huge_attempt])
    assert_error(attempt_errors, "events.attempt", "must_be_contiguous")
  end

  test "blocked event histories require parent unlock evidence" do
    parent_queued =
      terminal_event()
      |> Map.merge(%{
        "event_id" => "e225fb32-cd7f-4699-af3e-ed342910071b",
        "job_id" => @parent_job_id,
        "sequence" => 1,
        "type" => "job.queued",
        "status" => "queued",
        "data" => %{}
      })

    parent_running =
      parent_queued
      |> Map.merge(%{
        "event_id" => "f39f9977-b71b-48a4-ae79-4f5dd6ec76f5",
        "sequence" => 2,
        "type" => "job.running",
        "status" => "running",
        "data" => %{"environment" => "opencode"}
      })

    parent_succeeded =
      terminal_event()
      |> Map.put("job_id", @parent_job_id)
      |> Map.put("sequence", 3)

    blocked =
      terminal_event()
      |> Map.merge(%{
        "event_id" => "44e14c91-740e-494c-b0f7-eaa2a05b689e",
        "sequence" => 1,
        "type" => "job.blocked",
        "status" => "blocked",
        "data" => %{"depends_on" => [@parent_job_id]}
      })

    queued =
      terminal_event()
      |> Map.merge(%{
        "event_id" => "d879b484-b5d9-48a2-bfa1-e1975c448ba1",
        "sequence" => 2,
        "type" => "job.queued",
        "status" => "queued",
        "data" => %{"depends_on" => [@parent_job_id], "unlock_event_id" => @event_id}
      })

    stream = [parent_queued, parent_running, parent_succeeded, blocked, queued]
    assert {:ok, ^stream} = V1.validate_event_stream(stream)

    assert {:error, errors} =
             V1.validate_event_stream(
               stream
               |> List.replace_at(4, put_in(queued, ["data"], %{}))
             )

    assert_error(errors, "events.status", "invalid_history")

    unknown_unlock =
      put_in(
        queued,
        ["data", "unlock_event_id"],
        "5fdb4936-96f2-4934-af09-e2862d625940"
      )

    assert {:error, unlock_errors} =
             V1.validate_event_stream(List.replace_at(stream, 4, unknown_unlock))

    assert_error(
      unlock_errors,
      "events.data.unlock_event_id",
      "dependency_success_event_required"
    )
  end

  test "contract envelopes round-trip through JSON without shape drift" do
    request =
      single_request(%{"instruction" => "change code", "context" => %{"flags" => [true, nil, 3]}})

    encoded = Jason.encode!(request)
    assert Jason.decode!(encoded) == request
    assert {:ok, ^request} = request |> Jason.encode!() |> Jason.decode!() |> V1.validate_single()
  end

  defp single_request(payload \\ %{"instruction" => "implement the job"}) do
    %{
      "schema_version" => 1,
      "idempotency_key" => "client-job-1",
      "correlation_id" => "workflow-42",
      "repo" => "omashiki",
      "environment" => "opencode",
      "payload" => payload,
      "priority" => 1
    }
  end

  defp batch_job(ref, depends_on \\ []) do
    %{
      "ref" => ref,
      "idempotency_key" => "key-#{ref}",
      "repo" => "omashiki",
      "environment" => "opencode",
      "payload" => %{"instruction" => ref},
      "priority" => 1,
      "depends_on" => depends_on
    }
  end

  defp successful_result do
    %{
      "schema_version" => 1,
      "job_id" => @job_id,
      "attempt" => 1,
      "status" => "succeeded",
      "branch" => "feat-contract",
      "base_sha" => @sha,
      "head_sha" => @sha,
      "worktree_clean" => true,
      "result" => %{"summary" => "complete"},
      "finished_at" => "2026-08-24T03:00:00Z"
    }
  end

  defp terminal_event do
    %{
      "schema_version" => 1,
      "event_id" => @event_id,
      "job_id" => @job_id,
      "attempt" => 1,
      "sequence" => 4,
      "type" => "job.succeeded",
      "status" => "succeeded",
      "occurred_at" => "2026-08-24T03:00:00Z",
      "data" => %{"branch" => "feat-contract", "head_sha" => @sha}
    }
  end

  defp error_object do
    %{"code" => "runner_failed", "message" => "runner failed", "details" => %{}}
  end

  defp admission_response(status), do: admission_response(status, nil, @job_id)

  defp admission_response(status, depends_on),
    do: admission_response(status, depends_on, @job_id)

  defp admission_response(status, depends_on, job_id) do
    response = %{
      "schema_version" => 1,
      "job_id" => job_id,
      "idempotency_key" => "client-job-#{job_id}",
      "correlation_id" => "workflow-42",
      "repo" => "omashiki",
      "environment" => "opencode",
      "priority" => 1,
      "status" => status,
      "attempt" => 1,
      "submitted_at" => "2026-08-24T02:00:00Z"
    }

    if is_list(depends_on), do: Map.put(response, "depends_on", depends_on), else: response
  end

  defp transition(operation, from, to, from_attempt \\ 1, to_attempt \\ 1) do
    %{
      "schema_version" => 1,
      "job_id" => @job_id,
      "operation" => operation,
      "from_status" => from,
      "to_status" => to,
      "from_attempt" => from_attempt,
      "to_attempt" => to_attempt
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp assert_error(errors, field, code) do
    assert %{field: field, code: code} in errors
  end
end
