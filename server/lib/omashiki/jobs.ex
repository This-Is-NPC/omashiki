defmodule Omashiki.Jobs do
  @moduledoc "DB-authoritative claims, leases, retries, cancellation, and recovery."

  import Ecto.Query

  require Logger

  alias Omashiki.HostSettings
  alias Omashiki.Jobs.{DispatchWorker, ExecutionCapacity, Job, JobAttempt, JobEvent, Webhooks}
  alias Omashiki.Repo

  @terminal ~w(succeeded failed cancelled)
  @active ~w(provisioning running)
  @transitions %{
    "blocked" => ~w(cancelled),
    "queued" => ~w(provisioning cancelled),
    "provisioning" => ~w(running succeeded failed cancelled),
    "running" => ~w(succeeded failed cancelled)
  }
  @default_lease_ms 30_000

  # Liveness of a dispatch is decided by Oban's own `:incomplete` set — the very
  # set `DispatchWorker`'s uniqueness keys on. Deriving it from
  # `Oban.Job.unique_states/1` keeps the sweep and the uniqueness rule from
  # drifting apart: when no dispatch exists in one of these states, no dispatch
  # can ever run for that job again, and a re-insert would be permitted.
  @oban_incomplete_states Enum.map(Oban.Job.unique_states(:incomplete), &Atom.to_string/1)

  # Every path that parks a job at `queued` inserts its dispatch in the same
  # transaction, so the two become visible atomically and a grace period is not
  # strictly required. It is kept as defence in depth: cancelling a live job by
  # mistake destroys user work, whereas delaying an already-stranded row by half
  # a minute costs nothing. The asymmetry justifies the wait.
  @orphan_grace_ms 30_000

  @event_data_keys %{
    "blocked" => ~w(parent_job_id),
    "queued" => ~w(parent_job_id unlock_event_id retry),
    "provisioning" => ~w(runner_id),
    "running" => [],
    "succeeded" => ~w(branch base_sha head_sha),
    "failed" => ~w(error_code recovered),
    "cancelled" => ~w(error_code recovered)
  }

  @doc "Claim one queued job and reserve one of the global local execution slots."
  def claim(job_or_id, runner_id, opts \\ [])

  def claim(job_or_id, runner_id, opts) when is_binary(runner_id) do
    with {:ok, job_id} <- job_id(job_or_id),
         true <- runner_id != "" do
      lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)

      Repo.transaction(fn ->
        now = now()

        # Stale-lease reclamation belongs to `Jobs.Recovery` alone. Running it
        # inline made every claim scan and `FOR UPDATE` every expired attempt.
        case locked_job(job_id) do
          nil -> Repo.rollback(:not_found)
          %Job{status: "queued"} = job -> claim_locked(job, runner_id, now, lease_ms)
          %Job{status: status} -> Repo.rollback({:not_queued, status})
        end
      end)
      |> normalize_transaction_result()
      |> notify_job()
    else
      false -> {:error, :invalid_runner_id}
      error -> error
    end
  end

  def claim(_, _, _), do: {:error, :invalid_claim}

  @doc "Refresh a lease using its fencing token."
  def heartbeat(attempt_or_id, lease_token, opts \\ [])

  def heartbeat(attempt_or_id, lease_token, opts) when is_binary(lease_token) do
    with {:ok, attempt_id} <- attempt_id(attempt_or_id),
         true <- lease_token != "" do
      lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)

      Repo.transaction(fn ->
        now = now()

        case locked_attempt(attempt_id) do
          nil -> Repo.rollback(:not_found)
          attempt -> refresh_lease!(attempt, lease_token, now, lease_ms)
        end
      end)
      |> normalize_transaction_result()
      |> notify_job()
    else
      false -> {:error, :invalid_lease_token}
      error -> error
    end
  end

  def heartbeat(_, _, _), do: {:error, :invalid_lease}

  @doc "Advance a claimed provisioning attempt to running without changing its fence."
  def mark_running(attempt_or_id, lease_token) when is_binary(lease_token) do
    with {:ok, attempt_id} <- attempt_id(attempt_or_id) do
      Repo.transaction(fn ->
        now = now()

        case locked_attempt_with_job(attempt_id) do
          nil ->
            Repo.rollback(:not_found)

          %{attempt: attempt, job: job} ->
            assert_lease!(attempt, lease_token, now)

            if attempt.status != "provisioning" or job.status != "provisioning" do
              Repo.rollback({:invalid_transition, attempt.status, "running"})
            end

            update_attempt!(attempt, %{
              status: "running",
              heartbeat_at: now
            })

            updated = update_job!(job, %{status: "running"})
            record_event!(updated, "running", %{"runner_id" => attempt.runner_id})
            updated
        end
      end)
      |> normalize_transaction_result()
      |> notify_job()
    end
  end

  @doc "Complete an attempt through its fenced, idempotent terminal boundary."
  def complete(attempt_or_id, lease_token, status, attrs \\ %{})

  def complete(attempt_or_id, lease_token, status, attrs)
      when is_binary(lease_token) and is_map(attrs) do
    with {:ok, attempt_id} <- attempt_id(attempt_or_id),
         status <- normalize_status(status),
         :ok <- valid_terminal(status) do
      Repo.transaction(fn ->
        now = now()

        case locked_attempt_with_job(attempt_id) do
          nil ->
            Repo.rollback(:not_found)

          %{attempt: %JobAttempt{status: attempt_status} = attempt}
          when attempt_status in @terminal ->
            attempt

          %{attempt: attempt, job: job} ->
            assert_lease!(attempt, lease_token, now)
            complete_locked(job, attempt, status, attrs, now)
            Repo.get!(JobAttempt, attempt.id)
        end
      end)
      |> normalize_transaction_result()
    end
  end

  def complete(_, _, _, _), do: {:error, :invalid_completion}

  @doc "Advance a job in a transaction, unlocking direct children only on success."
  def transition(job_or_id, status, attrs \\ %{}) when is_map(attrs) do
    with {:ok, job_id} <- job_id(job_or_id),
         status <- normalize_status(status),
         :ok <- valid_status(status) do
      Repo.transaction(fn -> transition_locked(job_id, status, attrs) end)
      |> normalize_transaction_result()
      |> notify_job()
    end
  end

  @doc "Compatibility entrypoint for local runners: claim and immediately enter running."
  def start(job_or_id) do
    with {:ok, attempt} <- claim(job_or_id, "local-start"),
         {:ok, job} <- mark_running(attempt, attempt.lease_token) do
      {:ok, job}
    end
  end

  def succeed(job_or_id, attrs) when is_map(attrs),
    do: fenced_terminal(job_or_id, "succeeded", attrs)

  def fail(job_or_id, attrs \\ %{}) when is_map(attrs),
    do: fenced_terminal(job_or_id, "failed", attrs)

  @doc "Cancel a job once; repeated cancellation calls return the existing terminal row."
  def cancel(job_or_id, attrs \\ %{}) when is_map(attrs) do
    case transition(
           job_or_id,
           "cancelled",
           Map.put_new(attrs, :error, default_error("cancelled"))
         ) do
      {:ok, %Job{} = job} = result ->
        :ok =
          Omashiki.Runtime.AttemptSupervisor.cancel_job(
            job.id,
            job.current_attempt
          )

        result

      other ->
        other
    end
  end

  @doc "Create the next numbered queued attempt after a failed or cancelled attempt."
  def retry(job_or_id), do: transition(job_or_id, "queued", %{retry: true})

  @doc "Mark every expired active lease failed and release its capacity exactly once."
  def recover_stale(at \\ nil) do
    at = at || now()

    Repo.transaction(fn -> recover_stale_locked(at) end)
    |> normalize_transaction_result()
  end

  @doc """
  Cancel queued jobs whose Oban dispatch is gone, together with their queued attempt.

  `recover_stale/1` cannot see these rows. It scans attempts `where: a.status in
  @active`, and a job that was never claimed still carries its attempt at
  `queued` — `Jobs.Admission` inserts attempt number 1 alongside the job row. So
  the loss is two rows deep: the job *and* its attempt are parked at `queued`
  with no dispatch left to move either of them. Both are driven to a terminal
  state here; sweeping only the job row would leave the attempt orphaned.

  Terminal state is `cancelled`, never `failed`: a job that never started has a
  null `started_at`, which `jobs_start_timestamps` forbids for `failed`.
  """
  def recover_orphaned_dispatches(at \\ nil) do
    at = at || now()

    Repo.transaction(fn -> recover_orphaned_locked(at) end)
    |> normalize_transaction_result()
  end

  @doc "Reconcile the slot budget with `[limits].max_concurrent_containers`."
  def sync_capacity do
    requested = HostSettings.get_max_concurrent_containers()

    case set_capacity(requested) do
      {:ok, %ExecutionCapacity{capacity: ^requested}} = ok ->
        ok

      {:ok, %ExecutionCapacity{capacity: clamped}} = ok ->
        Logger.warning(
          "execution capacity held at #{clamped}: #{clamped} slot(s) still reserved, requested #{requested}"
        )

        ok

      {:error, reason} = error ->
        Logger.error("execution capacity sync failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Set the global execution slot count.

  Clamped up to the reservations already outstanding so the row never
  violates `active <= capacity`; the surplus drains on the next boot.
  """
  def set_capacity(capacity) when is_integer(capacity) and capacity > 0 do
    query =
      from(c in ExecutionCapacity,
        where: c.id == 1,
        update: [
          set: [
            capacity: fragment("GREATEST(?, ?)", type(^capacity, :integer), c.active),
            updated_at: ^now()
          ]
        ],
        select: c
      )

    case Repo.update_all(query, []) do
      {1, [row]} -> {:ok, row}
      {0, []} -> {:error, :not_found}
    end
  end

  def set_capacity(_), do: {:error, :invalid_capacity}

  defp claim_locked(%Job{} = job, runner_id, now, lease_ms) do
    reserve_capacity!()
    token = new_lease_token()
    expires_at = lease_until(now, lease_ms)
    attempt = current_attempt!(job)

    updated_job = update_job!(job, %{status: "provisioning", started_at: now})

    update_attempt!(attempt, %{
      status: "provisioning",
      runner_id: runner_id,
      lease_token: token,
      lease_expires_at: expires_at,
      heartbeat_at: now,
      claimed_at: now,
      capacity_reserved: true,
      started_at: now
    })

    record_event!(updated_job, "provisioning", %{"runner_id" => runner_id})
    Repo.get!(JobAttempt, attempt.id)
  end

  defp refresh_lease!(attempt, token, now, lease_ms) do
    assert_lease!(attempt, token, now)
    update_attempt!(attempt, %{heartbeat_at: now, lease_expires_at: lease_until(now, lease_ms)})
  end

  defp assert_lease!(%JobAttempt{} = attempt, token, now) do
    cond do
      attempt.status not in @active ->
        Repo.rollback(:attempt_not_active)

      attempt.lease_token != token ->
        Repo.rollback(:stale_lease)

      is_nil(attempt.lease_expires_at) or DateTime.compare(attempt.lease_expires_at, now) != :gt ->
        Repo.rollback(:lease_expired)

      true ->
        :ok
    end
  end

  defp complete_locked(job, attempt, "succeeded", attrs, now) do
    result = get_attr(attrs, :result)
    branch = get_attr(attrs, :branch)
    base_sha = get_attr(attrs, :base_sha)
    head_sha = get_attr(attrs, :head_sha)
    worktree_clean = get_attr(attrs, :worktree_clean)

    if is_map(result) and is_binary(branch) and is_binary(base_sha) and is_binary(head_sha) and
         worktree_clean == true do
      updated =
        update_job!(job, %{
          status: "succeeded",
          finished_at: now,
          terminal_result: result,
          terminal_error: nil
        })

      completed_attempt =
        update_attempt!(attempt, %{
          status: "succeeded",
          finished_at: now,
          branch: branch,
          base_sha: base_sha,
          head_sha: head_sha,
          worktree_clean: true,
          result: result,
          error: nil,
          capacity_reserved: false,
          lease_token: nil,
          lease_expires_at: nil
        })

      release_capacity_if_reserved!(attempt)

      event =
        record_event!(
          updated,
          "succeeded",
          %{
            "branch" => branch,
            "base_sha" => base_sha,
            "head_sha" => head_sha
          },
          completed_attempt
        )

      unlock_children!(updated, event.event_id)
      updated
    else
      Repo.rollback(:invalid_success_result)
    end
  end

  defp complete_locked(job, attempt, status, attrs, now) when status in ~w(failed cancelled) do
    error = get_attr(attrs, :error) || default_error(status)

    updated =
      update_job!(job, %{
        status: status,
        finished_at: now,
        terminal_result: nil,
        terminal_error: error
      })

    completed_attempt =
      update_attempt!(attempt, %{
        status: status,
        finished_at: now,
        error: error,
        capacity_reserved: false,
        lease_token: nil,
        lease_expires_at: nil
      })

    release_capacity_if_reserved!(attempt)
    record_event!(updated, status, %{"error_code" => error_code(error)}, completed_attempt)
    updated
  end

  defp fenced_terminal(job_or_id, status, attrs) do
    with {:ok, id} <- job_id(job_or_id) do
      case Repo.one(
             from(a in JobAttempt,
               where: a.job_id == ^id and a.status in ^@active,
               order_by: [desc: a.number],
               limit: 1
             )
           ) do
        %JobAttempt{lease_token: token} = attempt when is_binary(token) ->
          complete(attempt, token, status, attrs) |> completion_job()

        nil ->
          transition(id, status, attrs)
      end
    end
  end

  defp completion_job({:ok, %JobAttempt{job_id: id}}), do: {:ok, Repo.get!(Job, id)}
  defp completion_job(result), do: result

  defp transition_locked(job_id, status, attrs) do
    case locked_job(job_id) do
      nil ->
        Repo.rollback(:not_found)

      %Job{status: ^status} = job when status in @terminal ->
        job

      %Job{} = job ->
        retry? = get_attr(attrs, :retry) == true

        if status in ~w(succeeded failed) and job.status in @active do
          Repo.rollback(:lease_required)
        else
          if status in Map.get(@transitions, job.status, []) or
               (status == "queued" and job.status in ~w(failed cancelled) and retry?) do
            apply_transition(job, status, attrs)
          else
            Repo.rollback({:invalid_transition, job.status, status})
          end
        end
    end
  end

  defp apply_transition(%Job{} = job, "running", _attrs) do
    attempt = current_attempt!(job)
    now = now()

    if attempt.status == "provisioning" do
      update_attempt!(attempt, %{status: "running", heartbeat_at: now})
      updated = update_job!(job, %{status: "running"})
      record_event!(updated, "running", %{})
      updated
    else
      Repo.rollback({:invalid_transition, job.status, "running"})
    end
  end

  defp apply_transition(%Job{} = job, status, attrs) when status in ~w(failed cancelled) do
    attempt = current_attempt!(job)
    complete_locked(job, attempt, status, attrs, now())
  end

  defp apply_transition(%Job{} = job, "succeeded", attrs) do
    attempt = current_attempt!(job)
    complete_locked(job, attempt, "succeeded", attrs, now())
  end

  defp apply_transition(%Job{} = job, "queued", %{retry: true}) do
    if job.status in ~w(failed cancelled) do
      now = now()
      number = job.current_attempt + 1

      updated =
        update_job!(job, %{
          status: "queued",
          current_attempt: number,
          queued_at: now,
          started_at: nil,
          finished_at: nil,
          terminal_result: nil,
          terminal_error: nil
        })

      insert_attempt!(updated, %{number: number, status: "queued"})
      record_event!(updated, "queued", %{"retry" => true, "attempt" => number})
      enqueue!(updated)
      updated
    else
      Repo.rollback({:invalid_transition, job.status, "queued"})
    end
  end

  defp unlock_children!(%Job{} = parent, unlock_event_id) do
    children =
      from(j in Job,
        where: j.parent_job_id == ^parent.id and j.status == "blocked",
        order_by: [asc: j.priority, asc: j.inserted_at, asc: j.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    now = now()

    Enum.each(children, fn child ->
      updated = update_job!(child, %{status: "queued", queued_at: now})
      attempt = current_attempt!(updated)
      update_attempt!(attempt, %{status: "queued"})

      record_event!(updated, "queued", %{
        "parent_job_id" => parent.id,
        "unlock_event_id" => unlock_event_id
      })

      enqueue!(updated)
    end)

    :ok
  end

  defp recover_stale_locked(at) do
    stale =
      from(a in JobAttempt,
        where: a.status in ^@active and a.lease_expires_at < ^at,
        order_by: [asc: a.lease_expires_at, asc: a.id]
      )
      |> Repo.all()

    Enum.reduce(stale, 0, fn candidate, recovered ->
      job = locked_job(candidate.job_id)
      attempt = job && locked_attempt(candidate.id)

      if attempt && attempt.status in @active and attempt.lease_expires_at < at and
           job.current_attempt == attempt.number and job.status in @active do
        error = %{
          "code" => "stale_attempt",
          "message" => "attempt lease expired",
          "details" => %{"attempt" => attempt.number}
        }

        now = now()

        updated =
          update_job!(job, %{
            status: "failed",
            finished_at: now,
            terminal_result: nil,
            terminal_error: error
          })

        completed_attempt =
          update_attempt!(attempt, %{
            status: "failed",
            finished_at: now,
            error: error,
            capacity_reserved: false,
            lease_token: nil,
            lease_expires_at: nil
          })

        release_capacity_if_reserved!(attempt)

        record_event!(
          updated,
          "failed",
          %{"error_code" => "stale_attempt", "recovered" => true},
          completed_attempt
        )

        recovered + 1
      else
        recovered
      end
    end)
  end

  defp recover_orphaned_locked(at) do
    cutoff = DateTime.add(at, -@orphan_grace_ms, :millisecond)

    cutoff
    |> orphaned_job_ids()
    |> Enum.reduce(0, fn job_id, recovered ->
      job = locked_job(job_id)

      # Re-check under the row lock. Between the scan and the lock a dispatch
      # may have been re-inserted, or the job claimed outright, and either makes
      # this row somebody else's business again.
      with %Job{status: "queued"} <- job,
           false <- incomplete_dispatch?(job.id),
           %JobAttempt{status: "queued"} = attempt <- locked_current_attempt(job) do
        cancel_orphaned!(job, attempt)
        recovered + 1
      else
        nil ->
          recovered

        %JobAttempt{} = attempt ->
          # The job says `queued` but its attempt disagrees. Claiming moves both
          # together, so this is a torn row rather than a stranded one; leave it
          # rather than force a terminal state over a state we do not understand.
          Logger.warning(
            "job #{job_id} is queued but attempt #{attempt.number} is #{attempt.status}; skipping orphan sweep"
          )

          recovered

        _ ->
          recovered
      end
    end)
  end

  # A `queued` job with no dispatch in any incomplete state: Oban discarded or
  # cancelled it, or the Pruner removed it outright. Nothing will ever move it.
  defp orphaned_job_ids(cutoff) do
    live_dispatch =
      from(o in Oban.Job,
        where:
          o.worker == "Omashiki.Jobs.DispatchWorker" and
            fragment("? ->> 'job_id' = ?::text", o.args, parent_as(:job).id) and
            o.state in ^@oban_incomplete_states,
        select: 1
      )

    from(j in Job,
      as: :job,
      where: j.status == "queued" and j.queued_at < ^cutoff,
      where: not exists(live_dispatch),
      order_by: [asc: j.queued_at, asc: j.id],
      select: j.id
    )
    |> Repo.all()
  end

  defp incomplete_dispatch?(job_id) do
    from(o in Oban.Job,
      where:
        o.worker == "Omashiki.Jobs.DispatchWorker" and
          fragment("(?->>'job_id')", o.args) == ^job_id and
          o.state in ^@oban_incomplete_states
    )
    |> Repo.exists?()
  end

  defp locked_current_attempt(%Job{} = job) do
    from(a in JobAttempt,
      where: a.job_id == ^job.id and a.number == ^job.current_attempt,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp cancel_orphaned!(%Job{} = job, %JobAttempt{} = attempt) do
    error = %{
      "code" => "orphaned_dispatch",
      "message" => "no dispatch remains for this queued job",
      "details" => %{"attempt" => attempt.number}
    }

    now = now()

    updated =
      update_job!(job, %{
        status: "cancelled",
        finished_at: now,
        terminal_result: nil,
        terminal_error: error
      })

    completed_attempt =
      update_attempt!(attempt, %{
        status: "cancelled",
        finished_at: now,
        error: error,
        capacity_reserved: false,
        lease_token: nil,
        lease_expires_at: nil
      })

    release_capacity_if_reserved!(attempt)

    record_event!(
      updated,
      "cancelled",
      %{"error_code" => "orphaned_dispatch", "recovered" => true},
      completed_attempt
    )

    updated
  end

  defp reserve_capacity! do
    query =
      from(c in ExecutionCapacity,
        where: c.id == 1 and c.active < c.capacity,
        update: [inc: [active: 1]],
        select: c
      )

    case Repo.update_all(query, []) do
      {1, [capacity]} -> capacity
      {0, []} -> Repo.rollback(:capacity_exhausted)
    end
  end

  defp release_capacity_if_reserved!(%JobAttempt{capacity_reserved: true}) do
    release_capacity!()
  end

  defp release_capacity_if_reserved!(_), do: :ok

  defp release_capacity! do
    case Repo.update_all(from(c in ExecutionCapacity, where: c.id == 1 and c.active > 0),
           inc: [active: -1]
         ) do
      {1, _} -> :ok
      {0, _} -> Repo.rollback(:capacity_underflow)
    end
  end

  defp update_job!(%Job{} = job, attrs) do
    case job |> Job.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback({:persistence, changeset})
    end
  end

  defp update_attempt!(%JobAttempt{} = attempt, attrs) do
    case attempt |> JobAttempt.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback({:persistence, changeset})
    end
  end

  defp insert_attempt!(%Job{} = job, attrs) do
    case %JobAttempt{}
         |> JobAttempt.changeset(Map.put(attrs, :job_id, job.id))
         |> Repo.insert() do
      {:ok, attempt} -> attempt
      {:error, changeset} -> Repo.rollback({:persistence, changeset})
    end
  end

  defp record_event!(%Job{} = job, status, data, attempt \\ nil) do
    now = now()
    sequence = next_sequence(job.id)
    data = sanitize_event_data(status, data)

    attrs = %{
      job_id: job.id,
      attempt: job.current_attempt,
      sequence: sequence,
      type: "job.#{status}",
      status: status,
      step: status,
      outcome: status,
      correlation_id: job.correlation_id,
      occurred_at: now,
      recorded_at: now,
      data: data,
      schema_version: 1
    }

    case %JobEvent{} |> JobEvent.changeset(attrs) |> Repo.insert() do
      {:ok, event} when status in @terminal ->
        attempt = attempt || current_attempt!(job)
        :ok = Webhooks.enqueue_for_event!(job, attempt, event)
        event

      {:ok, event} ->
        event

      {:error, changeset} ->
        Repo.rollback({:persistence, changeset})
    end
  end

  defp enqueue!(%Job{} = job) do
    case Oban.insert(
           DispatchWorker.new(%{"job_id" => job.id},
             priority: job.priority,
             scheduled_at: job.queued_at
           )
         ) do
      {:ok, _oban_job} ->
        :ok

      {:error, changeset} ->
        if unique_dispatch_error?(changeset),
          do: retry_existing_dispatch!(job.id),
          else: Repo.rollback({:persistence, changeset})
    end
  end

  defp retry_existing_dispatch!(job_id) do
    case active_dispatch(job_id) do
      %Oban.Job{} = oban_job ->
        :ok = Oban.retry_job(oban_job)
        :ok

      nil ->
        Repo.rollback(:dispatch_not_persisted)
    end
  end

  defp active_dispatch(job_id) do
    from(j in Oban.Job,
      where:
        j.worker == "Omashiki.Jobs.DispatchWorker" and
          fragment("(?->>'job_id')", j.args) == ^job_id and
          j.state in ^["available", "scheduled", "retryable", "executing"],
      order_by: [desc: j.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp unique_dispatch_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:constraint] == :unique end)
  end

  defp unique_dispatch_error?(_), do: false

  defp next_sequence(job_id),
    do:
      (from(e in JobEvent, where: e.job_id == ^job_id, select: max(e.sequence)) |> Repo.one() || 0) +
        1

  defp locked_job(job_id),
    do: from(j in Job, where: j.id == ^job_id, lock: "FOR UPDATE") |> Repo.one()

  defp locked_attempt(id),
    do: from(a in JobAttempt, where: a.id == ^id, lock: "FOR UPDATE") |> Repo.one()

  defp locked_attempt_with_job(id) do
    case Repo.get(JobAttempt, id) do
      nil ->
        nil

      attempt ->
        case locked_job(attempt.job_id) do
          nil -> nil
          %Job{} = job -> %{attempt: locked_attempt(id), job: job}
        end
    end
  end

  defp current_attempt!(%Job{} = job) do
    case from(a in JobAttempt,
           where: a.job_id == ^job.id and a.number == ^job.current_attempt,
           lock: "FOR UPDATE"
         )
         |> Repo.one() do
      nil -> Repo.rollback(:attempt_not_found)
      attempt -> attempt
    end
  end

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp notify_job({:ok, %{id: job_id}} = result) when is_binary(job_id) do
    Phoenix.PubSub.broadcast(Omashiki.PubSub, "jobs", {:job_updated, job_id})
    Phoenix.PubSub.broadcast(Omashiki.PubSub, "job:#{job_id}", {:job_updated, job_id})
    result
  end

  defp notify_job({:ok, %{job_id: job_id}} = result) when is_binary(job_id) do
    Phoenix.PubSub.broadcast(Omashiki.PubSub, "jobs", {:job_updated, job_id})
    Phoenix.PubSub.broadcast(Omashiki.PubSub, "job:#{job_id}", {:job_updated, job_id})
    result
  end

  defp notify_job(result), do: result

  defp job_id(%Job{id: id}), do: job_id(id)
  defp job_id(id) when is_binary(id), do: {:ok, id}
  defp job_id(_), do: {:error, :invalid_job_id}

  defp attempt_id(%JobAttempt{id: id}), do: attempt_id(id)
  defp attempt_id(id) when is_binary(id), do: {:ok, id}
  defp attempt_id(_), do: {:error, :invalid_attempt_id}

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status), do: status

  defp valid_status(status)
       when status in ~w(blocked queued provisioning running succeeded failed cancelled),
       do: :ok

  defp valid_status(_), do: {:error, :invalid_status}
  defp valid_terminal(status) when status in @terminal, do: :ok
  defp valid_terminal(_), do: {:error, :invalid_terminal_status}

  defp get_attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp error_code(error) when is_map(error),
    do: Map.get(error, "code", Map.get(error, :code, "failed"))

  defp error_code(_), do: "failed"

  defp default_error(status), do: %{"code" => status, "message" => status, "details" => %{}}

  defp sanitize_event_data(status, data) do
    allowed = Map.fetch!(@event_data_keys, status)

    Enum.reduce(data, %{}, fn {key, value}, acc ->
      key = to_string(key)

      if key in allowed and safe_event_value?(value),
        do: Map.put(acc, key, value),
        else: acc
    end)
  end

  defp safe_event_value?(value) when is_boolean(value), do: true

  defp safe_event_value?(value) when is_binary(value),
    do: String.valid?(value) and byte_size(value) <= 255

  defp safe_event_value?(_), do: false

  defp lease_until(now, lease_ms), do: DateTime.add(now, lease_ms, :millisecond)
  defp new_lease_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp now, do: DateTime.utc_now(:microsecond)
end
