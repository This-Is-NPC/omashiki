defmodule Omashiki.Jobs.Contract.V1 do
  @moduledoc """
  Executable wire contract for queue jobs.

  The contract is deliberately independent from persistence, HTTP, Oban, and
  the agent runtime. Those layers consume this vocabulary in later slices.

  Terminal webhook delivery is token-configured, never job-configured. A
  terminal event and its outbox row commit together. Delivery is at-least-once
  and clients deduplicate by `event_id`; exactly-once delivery is not promised.
  The signed payload is canonical JSON with `event_id`, `timestamp`, job and
  attempt identity, status, correlation, and a redacted Git result. A delivery
  keeps its event timestamp and event ID across retries, so clients can reject
  stale/replayed IDs while accepting legitimate retries.
  """

  @version 1
  @max_payload_bytes 1_048_576
  @priorities 0..3
  @statuses ~w(blocked queued running succeeded failed cancelled)
  @terminal_statuses ~w(succeeded failed cancelled)

  @single_keys ~w(schema_version idempotency_key correlation_id repo environment payload priority depends_on base)
  @batch_keys ~w(schema_version correlation_id jobs)
  @batch_job_keys ~w(ref idempotency_key repo environment payload priority depends_on base)
  @admission_keys ~w(schema_version job_id idempotency_key correlation_id repo environment priority status attempt depends_on submitted_at)
  @batch_admission_keys ~w(schema_version correlation_id jobs)
  @transition_keys ~w(schema_version job_id operation from_status to_status from_attempt to_attempt depends_on unlock_event_id)
  @result_keys ~w(schema_version job_id attempt status branch base_sha head_sha worktree_clean result error finished_at)
  @event_keys ~w(schema_version event_id job_id attempt sequence type status occurred_at data)
  @error_keys ~w(code message details)

  @event_types ~w(
    job.blocked
    job.queued
    job.running
    job.succeeded
    job.failed
    job.cancelled
  )

  @observable_data_keys %{
    "job.blocked" => ~w(depends_on),
    "job.queued" => ~w(depends_on unlock_event_id retry),
    "job.running" => ~w(environment),
    "job.succeeded" => ~w(branch base_sha head_sha),
    "job.failed" => ~w(error_code),
    "job.cancelled" => ~w(error_code)
  }

  @type validation_error :: %{field: String.t(), code: String.t()}

  def version, do: @version
  def max_payload_bytes, do: @max_payload_bytes
  def statuses, do: @statuses
  def terminal_statuses, do: @terminal_statuses
  def event_types, do: @event_types

  def semantics do
    %{
      batch_admission: :atomic,
      execution: :independent,
      payload_limit_scope: :per_job_json_encoded,
      dependency_scope: :same_batch,
      dependency_failure_effect: :edge_policy,
      dependency_success_effect: :unlock_when_all_succeeded,
      retry_identity: :same_job_new_attempt,
      timeout_outcome: :failed,
      webhook_delivery: :at_least_once,
      webhook_idempotency_key: :event_id,
      webhook_payload_keys:
        ~w(schema_version event_id timestamp job_id attempt_id attempt status correlation_id git),
      webhook_signature: :hmac_sha256_timestamp_bound,
      webhook_retry_window_seconds: 86_400,
      timeout_source: :environment,
      success_artifact: :sink_dependent
    }
  end

  def retry_allowed?(status), do: status in ~w(failed cancelled)

  def validate_single(attrs) when is_map(attrs) do
    errors =
      attrs
      |> base_errors(
        @single_keys,
        ~w(schema_version idempotency_key correlation_id environment payload priority)
      )
      |> validate_nonempty(attrs, ~w(idempotency_key correlation_id environment))
      |> validate_optional_nonempty(attrs, "repo")
      |> validate_depends_on(attrs)
      |> validate_depends_on_on_failure(attrs)
      |> validate_priority(attrs)
      |> validate_payload(attrs, "payload")

    result(errors, attrs)
  end

  def validate_single(_), do: {:error, [error("$", "object_required")]}

  def validate_batch(attrs) when is_map(attrs) do
    errors =
      attrs
      |> base_errors(@batch_keys, ~w(schema_version correlation_id jobs))
      |> validate_nonempty(attrs, ["correlation_id"])
      |> validate_jobs(attrs)

    result(errors, attrs)
  end

  def validate_batch(_), do: {:error, [error("$", "object_required")]}

  def validate_single_response(attrs) when is_map(attrs) do
    errors =
      attrs
      |> base_errors(
        @admission_keys,
        ~w(schema_version job_id idempotency_key correlation_id repo environment priority status attempt submitted_at)
      )
      |> validate_uuid(attrs, "job_id")
      |> validate_nonempty(attrs, ~w(idempotency_key correlation_id environment))
      |> validate_optional_nonempty(attrs, "repo")
      |> validate_priority(attrs)
      |> validate_inclusion(attrs, "status", ~w(blocked queued))
      |> validate_exact_integer(attrs, "attempt", 1)
      |> validate_blocked_status_shape(attrs)
      |> validate_timestamp(attrs, "submitted_at")

    result(errors, attrs)
  end

  def validate_single_response(_), do: {:error, [error("$", "object_required")]}

  def validate_batch_response(attrs) when is_map(attrs) do
    errors =
      attrs
      |> base_errors(@batch_admission_keys, ~w(schema_version correlation_id jobs))
      |> validate_nonempty(attrs, ["correlation_id"])
      |> validate_admitted_jobs(attrs)

    result(errors, attrs)
  end

  def validate_batch_response(_), do: {:error, [error("$", "object_required")]}

  def validate_transition(attrs) when is_map(attrs) do
    errors =
      attrs
      |> base_errors(
        @transition_keys,
        ~w(schema_version job_id operation from_status to_status from_attempt to_attempt)
      )
      |> validate_uuid(attrs, "job_id")
      |> validate_inclusion(
        attrs,
        "operation",
        ~w(advance cancel timeout retry dependency_satisfied)
      )
      |> validate_inclusion(attrs, "from_status", @statuses)
      |> validate_inclusion(attrs, "to_status", @statuses)
      |> validate_positive_integer(attrs, "from_attempt")
      |> validate_positive_integer(attrs, "to_attempt")
      |> validate_transition_semantics(attrs)

    result(errors, attrs)
  end

  def validate_transition(_), do: {:error, [error("$", "object_required")]}

  def validate_transition_stream(transitions) when is_list(transitions) do
    transition_errors =
      transitions
      |> Enum.with_index()
      |> Enum.flat_map(fn {transition, index} ->
        case validate_transition(transition) do
          {:ok, _} -> []
          {:error, errors} -> prefix_errors(errors, "transitions.#{index}")
        end
      end)

    replay_errors =
      if transition_errors == [] do
        unlocks = Enum.filter(transitions, &(Map.get(&1, "operation") == "dependency_satisfied"))

        duplicate_errors(
          Enum.map(unlocks, &Map.fetch!(&1, "unlock_event_id")),
          "transitions.unlock_event_id"
        ) ++
          duplicate_errors(
            Enum.map(
              unlocks,
              &"#{Map.fetch!(&1, "job_id")}:#{Map.fetch!(&1, "from_attempt")}"
            ),
            "transitions.dependency_unlock"
          )
      else
        []
      end

    result(transition_errors ++ replay_errors, transitions)
  end

  def validate_transition_stream(_), do: {:error, [error("$", "array_required")]}

  def validate_result(attrs) when is_map(attrs) do
    errors =
      attrs
      |> base_errors(
        @result_keys,
        ~w(schema_version job_id attempt status finished_at)
      )
      |> validate_uuid(attrs, "job_id")
      |> validate_positive_integer(attrs, "attempt")
      |> validate_inclusion(attrs, "status", @terminal_statuses)
      |> validate_timestamp(attrs, "finished_at")
      |> validate_result_outcome(attrs)

    result(errors, attrs)
  end

  def validate_result(_), do: {:error, [error("$", "object_required")]}

  def validate_event(attrs) when is_map(attrs) do
    errors =
      attrs
      |> base_errors(
        @event_keys,
        ~w(schema_version event_id job_id attempt sequence type status occurred_at data)
      )
      |> validate_uuid(attrs, "event_id")
      |> validate_uuid(attrs, "job_id")
      |> validate_positive_integer(attrs, "attempt")
      |> validate_positive_integer(attrs, "sequence")
      |> validate_inclusion(attrs, "type", @event_types)
      |> validate_inclusion(attrs, "status", @statuses)
      |> validate_timestamp(attrs, "occurred_at")
      |> validate_json(attrs, "data")
      |> validate_event_status(attrs)
      |> validate_observation_data(attrs)
      |> validate_observation_shape(attrs)

    result(errors, attrs)
  end

  def validate_event(_), do: {:error, [error("$", "object_required")]}

  def validate_event_stream(events) when is_list(events) do
    event_errors =
      events
      |> Enum.with_index()
      |> Enum.flat_map(fn {event, index} ->
        case validate_event(event) do
          {:ok, _} -> []
          {:error, errors} -> prefix_errors(errors, "events.#{index}")
        end
      end)

    stream_errors =
      if event_errors == [] do
        validate_event_order(events) ++
          validate_terminal_attempts(events) ++ validate_parent_unlocks(events)
      else
        []
      end

    result(event_errors ++ stream_errors, events)
  end

  def validate_event_stream(_), do: {:error, [error("$", "array_required")]}

  defp base_errors(attrs, allowed, required) do
    []
    |> validate_unknown_keys(attrs, allowed)
    |> validate_required(attrs, required)
    |> validate_version(attrs)
  end

  defp validate_unknown_keys(errors, attrs, allowed) do
    attrs
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort_by(&inspect/1)
    |> Enum.reduce(errors, fn key, acc ->
      field = if is_binary(key), do: key, else: inspect(key)
      [error(field, "unknown_field") | acc]
    end)
  end

  defp validate_required(errors, attrs, required) do
    Enum.reduce(required, errors, fn key, acc ->
      if Map.has_key?(attrs, key), do: acc, else: [error(key, "required") | acc]
    end)
  end

  defp validate_version(errors, attrs) do
    case Map.fetch(attrs, "schema_version") do
      {:ok, @version} -> errors
      {:ok, _} -> [error("schema_version", "unsupported") | errors]
      :error -> errors
    end
  end

  defp validate_nonempty(errors, attrs, keys) do
    Enum.reduce(keys, errors, fn key, acc ->
      case Map.fetch(attrs, key) do
        {:ok, value} when is_binary(value) ->
          cond do
            not String.valid?(value) -> [error(key, "utf8_required") | acc]
            String.trim(value) == "" -> [error(key, "blank") | acc]
            true -> acc
          end

        {:ok, _} ->
          [error(key, "string_required") | acc]

        :error ->
          acc
      end
    end)
  end

  defp validate_optional_nonempty(errors, attrs, key) do
    if Map.has_key?(attrs, key), do: validate_nonempty(errors, attrs, [key]), else: errors
  end

  defp validate_priority(errors, attrs) do
    case Map.fetch(attrs, "priority") do
      {:ok, value} when is_integer(value) and value in @priorities -> errors
      {:ok, _} -> [error("priority", "must_be_between_0_and_3") | errors]
      :error -> errors
    end
  end

  defp validate_payload(errors, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        case Omashiki.Jobs.Contract.Payload.V2.validate(value) do
          {:ok, _} -> errors
          {:error, payload_errors} -> payload_errors ++ errors
        end

      :error ->
        errors
    end
  end

  defp validate_jobs(errors, attrs) do
    case Map.fetch(attrs, "jobs") do
      {:ok, jobs} when is_list(jobs) and jobs != [] ->
        job_errors =
          jobs
          |> Enum.with_index()
          |> Enum.flat_map(fn {job, index} -> validate_batch_job(job, index) end)

        errors ++ job_errors ++ validate_batch_relations(jobs)

      {:ok, []} ->
        [error("jobs", "must_not_be_empty") | errors]

      {:ok, _} ->
        [error("jobs", "array_required") | errors]

      :error ->
        errors
    end
  end

  defp validate_admitted_jobs(errors, attrs) do
    case Map.fetch(attrs, "jobs") do
      {:ok, jobs} when is_list(jobs) and jobs != [] ->
        batch_correlation_id = Map.get(attrs, "correlation_id")

        job_errors =
          jobs
          |> Enum.with_index()
          |> Enum.flat_map(fn {job, index} ->
            validation_errors =
              case validate_single_response(job) do
                {:ok, _} -> []
                {:error, errors} -> errors
              end

            correlation_errors =
              if is_map(job) and Map.get(job, "correlation_id") != batch_correlation_id do
                [error("correlation_id", "batch_mismatch")]
              else
                []
              end

            prefix_errors(validation_errors ++ correlation_errors, "jobs.#{index}")
          end)

        errors ++ job_errors ++ validate_admitted_relations(jobs)

      {:ok, []} ->
        [error("jobs", "must_not_be_empty") | errors]

      {:ok, _} ->
        [error("jobs", "array_required") | errors]

      :error ->
        errors
    end
  end

  defp validate_admitted_relations(jobs) do
    valid_jobs = Enum.filter(jobs, &is_map/1)
    job_ids = Enum.map(valid_jobs, &Map.get(&1, "job_id"))
    job_id_set = job_ids |> Enum.filter(&is_binary/1) |> MapSet.new()

    depends_on_errors =
      Enum.flat_map(valid_jobs, fn job ->
        job_id = Map.get(job, "job_id")
        depends_on = Map.get(job, "depends_on", [])

        if depends_on == [] do
          []
        else
          Enum.flat_map(depends_on, fn dep_id ->
            cond do
              not is_binary(dep_id) ->
                [error("jobs.depends_on", "uuid_required")]

              dep_id == job_id ->
                [error("jobs.depends_on", "self_dependency")]

              not MapSet.member?(job_id_set, dep_id) ->
                [error("jobs.depends_on", "unknown_job_id")]

              true ->
                []
            end
          end)
        end
      end)

    graph =
      Map.new(valid_jobs, fn job ->
        {Map.get(job, "job_id"), Map.get(job, "depends_on", [])}
      end)

    cycle_errors =
      if Enum.any?(Map.keys(graph), &dependency_cycle_from?(&1, graph, MapSet.new())),
        do: [error("jobs.depends_on", "cycle")],
        else: []

    duplicate_errors(job_ids, "jobs.job_id") ++ depends_on_errors ++ cycle_errors
  end

  defp validate_batch_job(job, index) when is_map(job) do
    prefix = "jobs.#{index}"

    job
    |> base_errors(
      @batch_job_keys,
      ~w(ref idempotency_key environment payload priority)
    )
    |> validate_nonempty(job, ~w(ref idempotency_key environment))
    |> validate_optional_nonempty(job, "repo")
    |> validate_depends_on(job)
    |> validate_priority(job)
    |> validate_payload(job, "payload")
    |> prefix_errors(prefix)
  end

  defp validate_batch_job(_, index), do: [error("jobs.#{index}", "object_required")]

  defp validate_batch_relations(jobs) do
    valid_jobs = Enum.filter(jobs, &is_map/1)
    refs = Enum.map(valid_jobs, &Map.get(&1, "ref"))
    idempotency_keys = Enum.map(valid_jobs, &Map.get(&1, "idempotency_key"))
    ref_set = refs |> Enum.filter(&is_binary/1) |> MapSet.new()

    duplicate_errors(refs, "jobs.ref") ++
      duplicate_errors(idempotency_keys, "jobs.idempotency_key") ++
      depends_on_errors(valid_jobs, ref_set) ++
      batch_cycle_errors(valid_jobs)
  end

  defp duplicate_errors(values, field) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn _ -> error(field, "duplicate") end)
  end

  defp depends_on_errors(jobs, ref_set) do
    Enum.flat_map(jobs, fn job ->
      ref = Map.get(job, "ref")

      Map.get(job, "depends_on", [])
      |> Enum.flat_map(fn dep ->
        base_errors =
          cond do
            not is_map(dep) ->
              [error("jobs.depends_on", "object_required")]

            is_binary(Map.get(dep, "ref")) and Map.get(dep, "ref") == ref ->
              [error("jobs.depends_on", "self_dependency")]

            is_binary(Map.get(dep, "ref")) and not MapSet.member?(ref_set, dep["ref"]) ->
              [error("jobs.depends_on", "unknown_ref")]

            is_binary(Map.get(dep, "id")) and is_binary(Map.get(dep, "ref")) ->
              [error("jobs.depends_on", "id_or_ref_required")]

            not (is_binary(Map.get(dep, "id")) or is_binary(Map.get(dep, "ref"))) ->
              [error("jobs.depends_on", "id_or_ref_required")]

            true ->
              []
          end

        on_failure_errors =
          case Map.get(dep, "on_failure") do
            nil -> []
            value when value in ~w(cancel block proceed) -> []
            _ -> [error("jobs.depends_on.on_failure", "unsupported")]
          end

        base_errors ++ on_failure_errors
      end)
    end)
  end

  defp batch_cycle_errors(jobs) do
    graph =
      Map.new(jobs, fn job ->
        deps =
          Map.get(job, "depends_on", [])
          |> Enum.map(fn
            %{"ref" => ref} -> ref
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        {Map.get(job, "ref"), deps}
      end)

    if Enum.any?(Map.keys(graph), &batch_cycle_from?(&1, graph, MapSet.new())) do
      [error("jobs.depends_on", "cycle")]
    else
      []
    end
  end

  defp batch_cycle_from?(ref, graph, path) do
    if MapSet.member?(path, ref) do
      true
    else
      graph
      |> Map.get(ref, [])
      |> Enum.any?(&batch_cycle_from?(&1, graph, MapSet.put(path, ref)))
    end
  end

  defp dependency_cycle_from?(job_id, graph, path) do
    if MapSet.member?(path, job_id) do
      true
    else
      graph
      |> Map.get(job_id, [])
      |> Enum.any?(&dependency_cycle_from?(&1, graph, MapSet.put(path, job_id)))
    end
  end

  defp validate_depends_on(errors, job) do
    case Map.fetch(job, "depends_on") do
      :error ->
        errors

      {:ok, deps} when is_list(deps) ->
        Enum.reduce(deps, errors, fn dep, acc ->
          cond do
            not is_map(dep) ->
              [error("depends_on", "object_required") | acc]

            is_binary(Map.get(dep, "id")) and is_binary(Map.get(dep, "ref")) ->
              [error("depends_on", "id_or_ref_required") | acc]

            not (is_binary(Map.get(dep, "id")) or is_binary(Map.get(dep, "ref"))) ->
              [error("depends_on", "id_or_ref_required") | acc]

            true ->
              acc
          end
        end)

      {:ok, _} ->
        [error("depends_on", "array_required") | errors]
    end
  end

  defp validate_depends_on_on_failure(errors, attrs) do
    case Map.fetch(attrs, "depends_on") do
      :error ->
        errors

      {:ok, deps} when is_list(deps) ->
        Enum.reduce(deps, errors, fn dep, acc ->
          if is_map(dep) do
            case Map.get(dep, "on_failure") do
              nil -> acc
              value when value in ~w(cancel block proceed) -> acc
              _ -> [error("depends_on.on_failure", "unsupported") | acc]
            end
          else
            acc
          end
        end)

      {:ok, _} ->
        errors
    end
  end

  defp validate_uuid(errors, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        case Ecto.UUID.cast(value) do
          {:ok, _} -> errors
          :error -> [error(key, "uuid_required") | errors]
        end

      :error ->
        errors
    end
  end

  defp validate_positive_integer(errors, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value > 0 -> errors
      {:ok, _} -> [error(key, "positive_integer_required") | errors]
      :error -> errors
    end
  end

  defp validate_exact_integer(errors, attrs, key, expected) do
    case Map.fetch(attrs, key) do
      {:ok, ^expected} -> errors
      {:ok, _} -> [error(key, "must_equal_#{expected}") | errors]
      :error -> errors
    end
  end

  defp validate_inclusion(errors, attrs, key, allowed) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        if value in allowed, do: errors, else: [error(key, "unsupported") | errors]

      :error ->
        errors
    end
  end

  defp validate_timestamp(errors, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        if String.valid?(value) do
          case DateTime.from_iso8601(value) do
            {:ok, _datetime, 0} -> errors
            _ -> [error(key, "utc_rfc3339_required") | errors]
          end
        else
          [error(key, "utc_rfc3339_required") | errors]
        end

      {:ok, _} ->
        [error(key, "utc_rfc3339_required") | errors]

      :error ->
        errors
    end
  end

  defp validate_blocked_status_shape(errors, attrs) do
    case {Map.get(attrs, "status"), Map.get(attrs, "depends_on") || []} do
      {"blocked", []} ->
        [error("depends_on", "required_when_blocked") | errors]

      {"queued", deps} when deps != [] ->
        [error("depends_on", "not_allowed_when_queued") | errors]

      _ ->
        errors
    end
  end

  defp validate_transition_semantics(errors, attrs) do
    operation = Map.get(attrs, "operation")
    from = Map.get(attrs, "from_status")
    to = Map.get(attrs, "to_status")
    from_attempt = Map.get(attrs, "from_attempt")
    to_attempt = Map.get(attrs, "to_attempt")

    valid? =
      case operation do
        "advance" ->
          {from, to} in [{"queued", "running"}, {"running", "succeeded"}, {"running", "failed"}] and
            to_attempt == from_attempt

        "cancel" ->
          from in ~w(blocked queued running) and to == "cancelled" and to_attempt == from_attempt

        "timeout" ->
          from == "running" and to == "failed" and to_attempt == from_attempt

        "retry" ->
          is_integer(from_attempt) and retry_allowed?(from) and to == "queued" and
            to_attempt == from_attempt + 1

        "dependency_satisfied" ->
          from == "blocked" and to == "queued" and to_attempt == from_attempt and
            is_list(Map.get(attrs, "depends_on")) and Map.get(attrs, "depends_on") != [] and
            not Enum.member?(Map.get(attrs, "depends_on") || [], Map.get(attrs, "job_id"))

        _ ->
          false
      end

    errors = if valid?, do: errors, else: [error("$", "invalid_transition") | errors]

    if operation == "dependency_satisfied" do
      errors
      |> require_present(attrs, ~w(depends_on unlock_event_id))
      |> validate_uuid(attrs, "unlock_event_id")
      |> validate_depends_on_ids(attrs, "depends_on")
    else
      forbid_present(errors, attrs, ~w(depends_on unlock_event_id))
    end
  end

  defp validate_result_outcome(errors, attrs) do
    case Map.get(attrs, "status") do
      "succeeded" ->
        errors
        |> require_present(attrs, ["result"])
        |> forbid_present(attrs, ["error"])
        |> validate_json(attrs, "result")
        |> validate_success_shape(attrs)

      status when status in ~w(failed cancelled) ->
        errors
        |> require_present(attrs, ["error"])
        |> forbid_present(attrs, ~w(branch base_sha head_sha worktree_clean result))
        |> validate_error_object(attrs)

      _ ->
        errors
    end
  end

  defp validate_success_shape(errors, attrs) do
    git_fields = ~w(branch base_sha head_sha worktree_clean)

    present =
      Enum.filter(git_fields, fn key ->
        Map.has_key?(attrs, key) and not is_nil(Map.get(attrs, key))
      end)

    cond do
      present == [] ->
        errors

      present == git_fields ->
        errors
        |> validate_nonempty(attrs, ["branch"])
        |> validate_sha(attrs, "base_sha")
        |> validate_sha(attrs, "head_sha")
        |> validate_true(attrs, "worktree_clean")

      true ->
        Enum.reduce(git_fields, errors, fn key, acc ->
          if Map.has_key?(attrs, key) and not is_nil(Map.get(attrs, key)),
            do: [error(key, "incoherent_git_shape") | acc],
            else: [error(key, "required") | acc]
        end)
    end
  end

  defp require_present(errors, attrs, keys), do: validate_required(errors, attrs, keys)

  defp forbid_present(errors, attrs, keys) do
    Enum.reduce(keys, errors, fn key, acc ->
      if Map.has_key?(attrs, key), do: [error(key, "not_allowed") | acc], else: acc
    end)
  end

  defp validate_sha(errors, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        if String.valid?(value) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value) do
          errors
        else
          [error(key, "git_sha_required") | errors]
        end

      {:ok, _} ->
        [error(key, "git_sha_required") | errors]

      :error ->
        errors
    end
  end

  defp validate_json(errors, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        if json_value?(value), do: errors, else: [error(key, "invalid_json_value") | errors]

      :error ->
        errors
    end
  end

  defp validate_true(errors, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, true} -> errors
      {:ok, _} -> [error(key, "must_be_true") | errors]
      :error -> errors
    end
  end

  defp validate_error_object(errors, attrs) do
    case Map.fetch(attrs, "error") do
      {:ok, value} when is_map(value) ->
        errors
        |> validate_unknown_keys(value, @error_keys)
        |> validate_required(value, ~w(code message))
        |> validate_nonempty(value, ~w(code message))
        |> validate_json(value, "details")
        |> prefix_errors("error")

      {:ok, _} ->
        [error("error", "object_required") | errors]

      :error ->
        errors
    end
  end

  defp validate_event_status(errors, attrs) do
    case {Map.get(attrs, "type"), Map.get(attrs, "status")} do
      {"job." <> suffix, status} when suffix == status ->
        errors

      {type, status} when type in @event_types and status in @statuses ->
        [error("status", "does_not_match_event_type") | errors]

      _ ->
        errors
    end
  end

  defp validate_depends_on_ids(errors, attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, ids} when is_list(ids) ->
        Enum.reduce(ids, errors, fn id, acc ->
          case Ecto.UUID.cast(id) do
            {:ok, _} -> acc
            :error -> [error("#{key}", "uuid_required") | acc]
          end
        end)

      {:ok, _} ->
        [error(key, "array_required") | errors]

      :error ->
        errors
    end
  end

  defp validate_observation_data(errors, attrs) do
    case {Map.get(attrs, "type"), Map.fetch(attrs, "data")} do
      {type, {:ok, data}} when is_map(data) and type in @event_types ->
        allowed = Map.fetch!(@observable_data_keys, type)

        Enum.reduce(data, errors, fn {key, value}, acc ->
          cond do
            not (is_binary(key) and key in allowed) ->
              [error("data", "unobservable_field") | acc]

            key == "retry" and not is_boolean(value) ->
              [error("data.retry", "boolean_required") | acc]

            key == "depends_on" and not is_list(value) ->
              [error("data.depends_on", "array_required") | acc]

            key == "depends_on" ->
              if Enum.all?(value, &match?({:ok, _}, Ecto.UUID.cast(&1))),
                do: acc,
                else: [error("data.depends_on", "uuid_required") | acc]

            key != "retry" and not is_binary(value) ->
              [error("data.#{key}", "string_required") | acc]

            true ->
              acc
          end
        end)

      {_type, {:ok, _data}} ->
        [error("data", "object_required") | errors]

      {_type, :error} ->
        errors
    end
  end

  defp validate_observation_shape(errors, attrs) do
    type = Map.get(attrs, "type")
    data = Map.get(attrs, "data")

    cond do
      not is_map(data) ->
        errors

      type == "job.blocked" ->
        errors
        |> require_present(data, ["depends_on"])
        |> validate_depends_on_ids(data, "depends_on")

      type == "job.queued" and Map.has_key?(data, "depends_on") ->
        errors
        |> require_present(data, ["unlock_event_id"])
        |> validate_depends_on_ids(data, "depends_on")
        |> validate_uuid(data, "unlock_event_id")

      type == "job.queued" and Map.has_key?(data, "unlock_event_id") ->
        [error("data.depends_on", "required") | errors]

      true ->
        errors
    end
  end

  defp validate_event_order(events) do
    duplicate_id_errors =
      events
      |> Enum.map(&Map.fetch!(&1, "event_id"))
      |> duplicate_errors("events.event_id")

    history_errors =
      events
      |> Enum.group_by(&Map.fetch!(&1, "job_id"))
      |> Enum.flat_map(fn {_job_id, job_events} ->
        sequences = Enum.map(job_events, &Map.fetch!(&1, "sequence"))

        sequence_errors =
          if sequences == Enum.sort(sequences) and Enum.uniq(sequences) == sequences do
            []
          else
            [error("events.sequence", "must_increase_per_job")]
          end

        state_errors =
          if valid_event_history?(job_events),
            do: [],
            else: [error("events.status", "invalid_history")]

        sequence_errors ++ state_errors
      end)

    duplicate_id_errors ++ history_errors
  end

  defp valid_event_history?([]), do: true

  defp valid_event_history?([first | rest]) do
    Map.fetch!(first, "attempt") == 1 and Map.fetch!(first, "status") in ~w(blocked queued) and
      Enum.reduce_while(rest, first, fn event, previous ->
        if valid_event_step?(previous, event), do: {:cont, event}, else: {:halt, false}
      end) != false
  end

  defp valid_event_step?(previous, current) do
    previous_status = Map.fetch!(previous, "status")
    current_status = Map.fetch!(current, "status")
    previous_attempt = Map.fetch!(previous, "attempt")
    current_attempt = Map.fetch!(current, "attempt")

    cond do
      current_attempt == previous_attempt ->
        {previous_status, current_status} in [
          {"blocked", "cancelled"},
          {"queued", "running"},
          {"queued", "cancelled"},
          {"running", "succeeded"},
          {"running", "failed"},
          {"running", "cancelled"}
        ] or
          (previous_status == "blocked" and current_status == "queued" and
             valid_parent_unlock_step?(previous, current))

      current_attempt == previous_attempt + 1 ->
        previous_status in ~w(failed cancelled) and current_status == "queued" and
          Map.get(Map.fetch!(current, "data"), "retry") == true

      true ->
        false
    end
  end

  defp valid_parent_unlock_step?(blocked_event, queued_event) do
    blocked_data = Map.fetch!(blocked_event, "data")
    queued_data = Map.fetch!(queued_event, "data")

    Map.get(blocked_data, "depends_on") == Map.get(queued_data, "depends_on") and
      match?({:ok, _}, Ecto.UUID.cast(Map.get(queued_data, "unlock_event_id")))
  end

  defp validate_parent_unlocks(events) do
    events_by_id = Map.new(events, &{Map.fetch!(&1, "event_id"), &1})

    events
    |> Enum.filter(&(Map.fetch!(&1, "status") == "queued"))
    |> Enum.flat_map(fn event ->
      data = Map.fetch!(event, "data")
      depends_on = Map.get(data, "depends_on", [])
      unlock_event_id = Map.get(data, "unlock_event_id")

      if depends_on != [] do
        case Map.get(events_by_id, unlock_event_id) do
          %{"job_id" => dep_id, "status" => "succeeded"} ->
            if Enum.member?(depends_on, dep_id),
              do: [],
              else: [error("events.data.unlock_event_id", "dependency_success_event_required")]

          _ ->
            [error("events.data.unlock_event_id", "dependency_success_event_required")]
        end
      else
        []
      end
    end)
  end

  defp validate_terminal_attempts(events) do
    terminal_events = Enum.filter(events, &(Map.fetch!(&1, "status") in @terminal_statuses))

    terminal_errors =
      terminal_events
      |> Enum.group_by(&{Map.fetch!(&1, "job_id"), Map.fetch!(&1, "attempt")})
      |> Enum.flat_map(fn {_attempt_identity, outcomes} ->
        if length(outcomes) > 1 do
          [error("events", "multiple_terminal_outcomes_per_attempt")]
        else
          []
        end
      end)

    attempt_errors =
      events
      |> Enum.group_by(&Map.fetch!(&1, "job_id"))
      |> Enum.flat_map(fn {_job_id, job_events} ->
        attempts = job_events |> Enum.map(&Map.fetch!(&1, "attempt")) |> Enum.uniq()

        contiguous? =
          attempts
          |> Enum.sort()
          |> Enum.with_index(1)
          |> Enum.all?(fn {attempt, expected} -> attempt == expected end)

        if contiguous? do
          []
        else
          [error("events.attempt", "must_be_contiguous")]
        end
      end)

    terminal_errors ++ attempt_errors
  end

  defp json_value?(nil), do: true

  defp json_value?(value) when is_binary(value), do: String.valid?(value)
  defp json_value?(value) when is_boolean(value) or is_integer(value), do: true

  defp json_value?(value) when is_float(value), do: value == value
  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.valid?(key) and json_value?(nested)
    end)
  end

  defp json_value?(_), do: false

  defp prefix_errors(errors, prefix) do
    Enum.map(errors, fn %{field: field} = validation_error ->
      field = if field == "$", do: prefix, else: "#{prefix}.#{field}"
      %{validation_error | field: field}
    end)
  end

  defp result([], attrs), do: {:ok, attrs}

  defp result(errors, _attrs) do
    {:error, Enum.reverse(errors)}
  end

  defp error(field, code), do: %{field: field, code: code}
end
