defmodule Omashiki.Jobs do
  @moduledoc "DB-authoritative claims, leases, retries, cancellation, and recovery."

  import Ecto.Query
  import Omashiki.Jobs.Statuses, only: [is_terminal: 1, is_unsuccessful: 1]

  require Logger

  alias Omashiki.Config
  alias Omashiki.HostSettings

  alias Omashiki.Jobs.{
    Admission,
    AttemptResult,
    DispatchWorker,
    ExecutionCapacity,
    Job,
    JobAttempt,
    JobEvent,
    Statuses,
    Webhooks
  }

  alias Omashiki.Repo
  alias Omashiki.Tx

  @transitions %{
    "blocked" => ~w(cancelled),
    "queued" => ~w(provisioning cancelled),
    "provisioning" => ~w(running succeeded failed cancelled),
    "running" => ~w(succeeded failed cancelled)
  }
  @default_lease_ms 30_000

  # The node name the pre-node singleton capacity row was re-keyed to. It is the
  # release target for attempts claimed before `job_attempts.machine_id` existed,
  # and nothing else: no live claim ever reserves against it unless a machine is
  # actually called `local`.
  @legacy_machine "local"

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
  @orphan_batch_size 100

  @event_data_keys %{
    "blocked" => ~w(depends_on),
    "queued" => ~w(depends_on unlock_event_id retry unclaimed runner_id),
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

      Tx.run(fn ->
        now = now()

        # Stale-lease reclamation belongs to `Jobs.Recovery` alone. Running it
        # inline made every claim scan and `FOR UPDATE` every expired attempt.
        case locked_job(job_id) do
          nil -> Repo.rollback(:not_found)
          %Job{status: "queued"} = job -> claim_locked(job, runner_id, now, lease_ms, opts)
          %Job{status: status} -> Repo.rollback({:not_queued, status})
        end
      end)
      |> notify_job()
    else
      false -> {:error, :invalid_runner_id}
      error -> error
    end
  end

  def claim(_, _, _), do: {:error, :invalid_claim}

  @doc """
  Claim the oldest queued job for a remote worker poll loop.

  Skips when `free_slots` is zero. `free_slots` is the worker-reported remaining
  semaphore; manager `execution_capacity` tracks in-flight attempts on this
  manager, not the worker host's container budget.
  """
  def claim_next(runner_id, opts \\ [])

  def claim_next(runner_id, opts) when is_binary(runner_id) do
    if Keyword.get(opts, :free_slots, 1) == 0 do
      {:ok, :empty}
    else
      with true <- runner_id != "" do
        lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)

        Tx.run(fn ->
          case next_queued_job() do
            nil -> :empty
            %Job{} = job -> claim_locked(job, runner_id, now(), lease_ms, opts)
          end
        end)
        |> notify_job()
      else
        false -> {:error, :invalid_runner_id}
      end
    end
  end

  def claim_next(_, _), do: {:error, :invalid_runner_id}

  @doc "Refresh a lease using its fencing token."
  def heartbeat(attempt_or_id, lease_token, opts \\ [])

  def heartbeat(attempt_or_id, lease_token, opts) when is_binary(lease_token) do
    with {:ok, attempt_id} <- attempt_id(attempt_or_id),
         true <- lease_token != "" do
      lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)

      Tx.run(fn ->
        now = now()

        case locked_attempt(attempt_id) do
          nil -> Repo.rollback(:not_found)
          attempt -> refresh_lease!(attempt, lease_token, now, lease_ms)
        end
      end)
      |> notify_job()
    else
      false -> {:error, :invalid_lease_token}
      error -> error
    end
  end

  def heartbeat(_, _, _), do: {:error, :invalid_lease}

  @doc """
  Release a provisioning attempt back to the queue without creating a new attempt.

  Used when a worker rejects an offer before execution starts.
  """
  def unclaim(attempt_or_id, lease_token) when is_binary(lease_token) do
    with {:ok, attempt_id} <- attempt_id(attempt_or_id),
         true <- lease_token != "" do
      Tx.run(fn ->
        now = now()

        case locked_attempt_with_job(attempt_id) do
          nil ->
            Repo.rollback(:not_found)

          %{attempt: attempt, job: job} ->
            assert_lease!(attempt, lease_token, now)
            previous_runner_id = attempt.runner_id

            cond do
              attempt.status == "running" ->
                Repo.rollback(:already_running)

              attempt.status != "provisioning" or job.status != "provisioning" ->
                Repo.rollback(:attempt_not_active)

              true ->
                release_capacity_if_reserved!(attempt)

                update_attempt!(attempt, %{
                  status: "queued",
                  runner_id: nil,
                  lease_token: nil,
                  lease_expires_at: nil,
                  heartbeat_at: nil,
                  claimed_at: nil,
                  started_at: nil,
                  capacity_reserved: false
                })

                updated = update_job!(job, %{status: "queued", started_at: nil})

                record_event!(updated, "queued", %{
                  "unclaimed" => true,
                  "runner_id" => previous_runner_id
                })

                updated
            end
        end
      end)
      |> notify_job()
    else
      false -> {:error, :invalid_lease_token}
      error -> error
    end
  end

  @doc "Advance a claimed provisioning attempt to running without changing its fence."
  def mark_running(attempt_or_id, lease_token) when is_binary(lease_token) do
    with {:ok, attempt_id} <- attempt_id(attempt_or_id) do
      Tx.run(fn ->
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
      Tx.run(fn ->
        now = now()

        case locked_attempt_with_job(attempt_id) do
          nil ->
            Repo.rollback(:not_found)

          %{attempt: %JobAttempt{status: attempt_status} = attempt}
          when is_terminal(attempt_status) ->
            attempt

          %{attempt: attempt, job: job} ->
            assert_lease!(attempt, lease_token, now)
            complete_locked(job, attempt, status, attrs, now)
            Repo.get!(JobAttempt, attempt.id)
        end
      end)
      |> notify_job()
    end
  end

  def complete(_, _, _, _), do: {:error, :invalid_completion}

  @doc "Advance a job in a transaction, unlocking direct children only on success."
  def transition(job_or_id, status, attrs \\ %{}) when is_map(attrs) do
    with {:ok, job_id} <- job_id(job_or_id),
         status <- normalize_status(status),
         :ok <- valid_status(status) do
      Tx.run(fn -> transition_locked(job_id, status, attrs) end)
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

    Tx.run(fn -> recover_stale_locked(at) end)
  end

  @doc """
  Cancel queued jobs whose Oban dispatch is gone, together with their queued attempt.

  `recover_stale/1` cannot see these rows. It scans attempts whose status is in
  `Statuses.active/0`, and a job that was never claimed still carries its attempt at
  `queued` — `Jobs.Admission` inserts attempt number 1 alongside the job row. So
  the loss is two rows deep: the job *and* its attempt are parked at `queued`
  with no dispatch left to move either of them. Both are driven to a terminal
  state here; sweeping only the job row would leave the attempt orphaned.

  Terminal state is `cancelled`, never `failed`: a job that never started has a
  null `started_at`, which `jobs_start_timestamps` forbids for `failed`.

  Rows are cancelled rather than re-enqueued. `DispatchWorker`'s uniqueness
  would permit the re-insert — `discarded` is not an incomplete state — but a
  row only reaches this sweep after Oban has already spent its five attempts,
  and the sweep re-runs every second with nothing to decrement. Re-enqueueing a
  permanently poisoned job would loop it between sweep and queue forever. The
  goal is that a lost dispatch be *visible* (NFR-001); `retry/1` is the
  deliberate, operator-driven way back into the queue.

  At most `#{@orphan_batch_size}` rows are cancelled per call; the caller's tick
  drains any larger backlog across successive passes.
  """
  def recover_orphaned_dispatches(at \\ nil) do
    at = at || now()

    Tx.run(fn -> recover_orphaned_locked(at) end)
  end

  @doc """
  Reconcile *this node's* slot budget with `[limits].max_concurrent_containers`.

  Each machine owns one row and reconciles only that row, so a second node
  booting no longer overwrites the first node's budget. The row is created here
  if it does not exist yet: boot is the only place a node's capacity row is
  written into being.

  After reconciling its own row, drops idle capacity rows for nodes that are not
  in `Config.nodes/0` — the declared cluster plus this host on a single-machine
  install. Rows with `active > 0` are left to drain; declared peers survive even
  when idle so a multi-node cluster still sums every live node.
  """
  def sync_capacity do
    requested = HostSettings.get_max_concurrent_containers()

    case set_capacity(requested) do
      {:ok, %ExecutionCapacity{capacity: ^requested}} = ok ->
        prune_phantom_capacity!()
        ok

      {:ok, %ExecutionCapacity{capacity: clamped}} = ok ->
        prune_phantom_capacity!()

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
  Set this node's execution slot count, creating its row if it has none.

  Clamped up to the reservations already outstanding so the row never
  violates `active <= capacity`; the surplus drains on the next boot.

  An upsert rather than an update, because a node's row has no other origin: the
  schema no longer ships a seeded singleton, and a machine joining the cluster
  must be able to declare its own budget without an operator inserting a row by
  hand. `active` is only supplied on insert — a conflicting row keeps the count
  it already holds.
  """
  def set_capacity(capacity) when is_integer(capacity) and capacity > 0 do
    now = now()

    on_conflict =
      from(c in ExecutionCapacity,
        update: [
          set: [
            capacity: fragment("GREATEST(EXCLUDED.capacity, ?)", c.active),
            updated_at: ^now
          ]
        ]
      )

    Repo.insert(
      %ExecutionCapacity{
        machine_id: Config.current_machine().name,
        capacity: capacity,
        active: 0,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: on_conflict,
      conflict_target: :machine_id,
      returning: true
    )
  end

  def set_capacity(_), do: {:error, :invalid_capacity}

  @doc """
  Total declared slots across every node, and the total currently reserved.

  The cluster ceiling is the sum of the rows, not any one machine's
  `[limits].max_concurrent_containers`: that value describes the host it is
  declared on and says nothing about the rest of the cluster.
  """
  def cluster_capacity do
    from(c in ExecutionCapacity,
      select: %{capacity: coalesce(sum(c.capacity), 0), active: coalesce(sum(c.active), 0)}
    )
    |> Repo.one()
  end

  defp prune_phantom_capacity! do
    allowed = Enum.map(Config.nodes(), & &1.name)

    from(c in ExecutionCapacity,
      where: c.machine_id not in ^allowed and c.active == 0
    )
    |> Repo.delete_all()
  end

  defp claim_locked(%Job{} = job, runner_id, now, lease_ms, opts) do
    # Manager execution_capacity tracks in-flight attempts on this host; worker
    # polls stamp the attempt with the polling worker's id, not this name.
    capacity_machine = Config.current_machine().name
    attempt_machine = attempt_machine_id(runner_id, opts)
    reserve_capacity!(capacity_machine)
    token = new_lease_token()
    expires_at = lease_until(now, lease_ms)
    attempt = current_attempt!(job)

    updated_job = update_job!(job, %{status: "provisioning", started_at: now})

    update_attempt!(attempt, %{
      status: "provisioning",
      runner_id: runner_id,
      machine_id: attempt_machine,
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
      attempt.status not in Statuses.active() ->
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

    if valid_success_result?(job, result, branch, base_sha, head_sha, worktree_clean) do
      updated =
        update_job!(job, %{
          status: "succeeded",
          finished_at: now,
          terminal_result: result,
          terminal_error: nil
        })

      attempt_attrs =
        %{
          status: "succeeded",
          finished_at: now,
          result: result,
          error: nil,
          capacity_reserved: false,
          lease_token: nil,
          lease_expires_at: nil,
          summary: AttemptResult.truncate_summary(get_attr(attrs, :summary)),
          changes: AttemptResult.sanitize_changes(get_attr(attrs, :changes)),
          compare_url: AttemptResult.resolve_compare_url(job, base_sha, head_sha)
        }
        |> maybe_put_git_fields(branch, base_sha, head_sha, worktree_clean)

      completed_attempt = update_attempt!(attempt, attempt_attrs)

      release_capacity_if_reserved!(attempt)

      event =
        record_event!(
          updated,
          "succeeded",
          success_event_data(branch, base_sha, head_sha),
          completed_attempt
        )

      Omashiki.Jobs.Dependencies.notify_dependents!(updated, event.event_id)
      updated
    else
      Repo.rollback(:invalid_success_result)
    end
  end

  defp complete_locked(job, attempt, status, attrs, now) when is_unsuccessful(status) do
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
    Omashiki.Jobs.Dependencies.notify_dependents!(updated, nil)
    updated
  end

  defp valid_success_result?(job, result, branch, base_sha, head_sha, worktree_clean) do
    case admitted_sink(job) do
      {:ok, "git"} ->
        git_success_result?(result, branch, base_sha, head_sha, worktree_clean)

      {:ok, sink} when sink in ["files", "none"] ->
        result_only_success_result?(result, branch, base_sha, head_sha, worktree_clean)

      _ ->
        false
    end
  end

  defp admitted_sink(%Job{admitted_environment: env}) when is_map(env) do
    case Map.get(env, "sink") || Map.get(env, :sink) do
      sink when sink in ["git", "files", "none"] -> {:ok, sink}
      _ -> :error
    end
  end

  defp admitted_sink(_), do: :error

  defp git_success_result?(result, branch, base_sha, head_sha, worktree_clean)
       when is_map(result) and is_binary(branch) and is_binary(base_sha) and
              is_binary(head_sha) and worktree_clean == true,
       do: true

  defp git_success_result?(_result, _branch, _base_sha, _head_sha, _worktree_clean), do: false

  defp result_only_success_result?(result, nil, nil, nil, nil) when is_map(result), do: true

  defp result_only_success_result?(_result, _branch, _base_sha, _head_sha, _worktree_clean),
    do: false

  defp maybe_put_git_fields(attrs, branch, base_sha, head_sha, true) do
    Map.merge(attrs, %{
      branch: branch,
      base_sha: base_sha,
      head_sha: head_sha,
      worktree_clean: true
    })
  end

  defp maybe_put_git_fields(attrs, _branch, _base_sha, _head_sha, _worktree_clean) do
    Map.merge(attrs, %{
      branch: nil,
      base_sha: nil,
      head_sha: nil,
      worktree_clean: nil
    })
  end

  defp lock_token_before_job!(job_id) do
    token_id =
      from(j in Job, where: j.id == ^job_id, select: j.api_token_id)
      |> Repo.one()

    if is_binary(token_id), do: Admission.lock_token!(token_id)
  end

  defp success_event_data(branch, base_sha, head_sha)
       when is_binary(branch) and is_binary(base_sha) and is_binary(head_sha) do
    %{"branch" => branch, "base_sha" => base_sha, "head_sha" => head_sha}
  end

  defp success_event_data(_branch, _base_sha, _head_sha), do: %{}

  defp fenced_terminal(job_or_id, status, attrs) do
    with {:ok, id} <- job_id(job_or_id) do
      case Repo.one(
             from(a in JobAttempt,
               where: a.job_id == ^id and a.status in ^Statuses.active(),
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
    if get_attr(attrs, :retry) == true do
      lock_token_before_job!(job_id)
    end

    case locked_job(job_id) do
      nil ->
        Repo.rollback(:not_found)

      %Job{status: ^status} = job when is_terminal(status) ->
        job

      %Job{} = job ->
        retry? = get_attr(attrs, :retry) == true

        if status in ~w(succeeded failed) and Statuses.active?(job.status) do
          Repo.rollback(:lease_required)
        else
          if status in Map.get(@transitions, job.status, []) or
               (status == "queued" and is_unsuccessful(job.status) and retry?) do
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

  defp apply_transition(%Job{} = job, status, attrs) when is_unsuccessful(status) do
    attempt = current_attempt!(job)
    complete_locked(job, attempt, status, attrs, now())
  end

  defp apply_transition(%Job{} = job, "succeeded", attrs) do
    attempt = current_attempt!(job)
    complete_locked(job, attempt, "succeeded", attrs, now())
  end

  defp apply_transition(%Job{} = job, "queued", %{retry: true}) do
    if is_binary(job.api_token_id) do
      # `transition_locked/3` already `FOR UPDATE`s this token before the job row.
      Admission.reject_over_capacity!(Repo.get!(Omashiki.ApiTokens.Token, job.api_token_id), 1)
    end

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
  end

  defp recover_stale_locked(at) do
    stale =
      from(a in JobAttempt,
        where: a.status in ^Statuses.active() and a.lease_expires_at < ^at,
        order_by: [asc: a.lease_expires_at, asc: a.id]
      )
      |> Repo.all()

    Enum.reduce(stale, 0, fn candidate, recovered ->
      job = locked_job(candidate.job_id)
      attempt = job && locked_attempt(candidate.id)

      if attempt && Statuses.active?(attempt.status) and attempt.lease_expires_at < at and
           job.current_attempt == attempt.number and Statuses.active?(job.status) do
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
      select: j.id,
      # One tick cancels at most a batch. A mass stranding (a node lost with a
      # full queue behind it) would otherwise lock and rewrite every row in a
      # single transaction; oldest-first order plus the 1s tick drains the
      # backlog across ticks instead, bounding how long those locks are held.
      limit: @orphan_batch_size
    )
    |> Repo.all()
  end

  # The row-locked twin of the `not exists` prefilter in `orphaned_job_ids/1`.
  # Same predicate, different shape: the prefilter correlates against the job
  # table to keep the scan set-based, this one takes a bound id after the lock.
  defp incomplete_dispatch?(job_id) do
    job_id
    |> dispatch_query()
    |> where([o], o.state in ^@oban_incomplete_states)
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

  # Still one row, still one atomic compare-and-swap — `active < capacity` and
  # the increment are the same statement, so two claimers racing for the last
  # slot cannot both win. The predicate selects this machine's row instead of
  # the singleton, which is the whole of the change. A node with no row has no
  # budget and claims nothing; boot is what gives it one.
  defp reserve_capacity!(machine) do
    query =
      from(c in ExecutionCapacity,
        where: c.machine_id == ^machine and c.active < c.capacity,
        update: [inc: [active: 1]],
        select: c
      )

    case Repo.update_all(query, []) do
      {1, [capacity]} -> capacity
      {0, []} -> Repo.rollback(:capacity_exhausted)
    end
  end

  # Release on the row that *reserved*. For direct claims that row is the
  # attempt's `machine_id`; for remote worker polls the manager reserved against
  # its own row while stamping the worker id on the attempt. Every caller here
  # also runs on the node that did not claim: `recover_stale/1` sweeps expired
  # leases cluster-wide, so node B routinely fails an attempt node A is holding a
  # slot for. Releasing against the sweeper would leave A one slot short forever
  # and drive B's counter below the reservations it actually holds — both rows
  # wrong, silently.
  #
  # A `nil` node predates `job_attempts.machine_id` and therefore predates any
  # cluster: those reservations were counted in the singleton this table's
  # migration re-keyed to `'local'`, so that is where they are given back.
  defp release_capacity_if_reserved!(%JobAttempt{capacity_reserved: true} = attempt) do
    release_capacity!(capacity_machine_for(attempt))
  end

  defp release_capacity_if_reserved!(_), do: :ok

  defp attempt_machine_id(runner_id, opts) do
    cond do
      machine_id = Keyword.get(opts, :machine_id) ->
        machine_id

      String.starts_with?(runner_id, "worker:") ->
        String.replace_prefix(runner_id, "worker:", "")

      true ->
        Config.current_machine().name
    end
  end

  defp capacity_machine_for(%JobAttempt{runner_id: "worker:" <> _}) do
    Config.current_machine().name
  end

  defp capacity_machine_for(%JobAttempt{machine_id: nil}), do: @legacy_machine

  defp capacity_machine_for(%JobAttempt{machine_id: machine_id}), do: machine_id

  defp release_capacity!(machine) do
    case Repo.update_all(
           from(c in ExecutionCapacity, where: c.machine_id == ^machine and c.active > 0),
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
      data: data
    }

    case %JobEvent{} |> JobEvent.changeset(attrs) |> Repo.insert() do
      {:ok, event} when is_terminal(status) ->
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
    job_id
    |> dispatch_query()
    |> where([o], o.state in ^@oban_incomplete_states)
    |> order_by([o], desc: o.id)
    |> limit(1)
    |> Repo.one()
  end

  defp dispatch_query(job_id) do
    from(o in Oban.Job,
      where:
        o.worker == "Omashiki.Jobs.DispatchWorker" and
          fragment("(?->>'job_id')", o.args) == ^job_id
    )
  end

  defp unique_dispatch_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:constraint] == :unique end)
  end

  defp unique_dispatch_error?(_), do: false

  defp next_sequence(job_id),
    do:
      (from(e in JobEvent, where: e.job_id == ^job_id, select: max(e.sequence)) |> Repo.one() || 0) +
        1

  defp next_queued_job do
    from(j in Job,
      where: j.status == "queued",
      order_by: [asc: j.inserted_at, asc: j.id],
      lock: "FOR UPDATE SKIP LOCKED",
      limit: 1
    )
    |> Repo.one()
  end

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

  @doc """
  Tell this node's subscribers that a job's visible state changed. Call it
  after the change commits, so a subscriber that reads again sees it.
  """
  def broadcast_updated(job_id) when is_binary(job_id) do
    Phoenix.PubSub.broadcast(Omashiki.PubSub, "jobs", {:job_updated, job_id})
    Phoenix.PubSub.broadcast(Omashiki.PubSub, "job:#{job_id}", {:job_updated, job_id})
    :ok
  end

  # An attempt carries both `id` and `job_id`; its job id has to win, or the
  # event names the attempt and "job:<id>" subscribers never hear about it.
  defp notify_job({:ok, %{job_id: job_id}} = result) when is_binary(job_id) do
    broadcast_updated(job_id)
    result
  end

  defp notify_job({:ok, %{id: job_id}} = result) when is_binary(job_id) do
    broadcast_updated(job_id)
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
  defp valid_terminal(status) when is_terminal(status), do: :ok
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

      if key in allowed and safe_event_value?(key, value),
        do: Map.put(acc, key, value),
        else: acc
    end)
  end

  defp safe_event_value?("depends_on", value) when is_list(value),
    do: value != [] and Enum.all?(value, &dependency_id_value?/1)

  defp safe_event_value?(_key, value) when is_boolean(value), do: true

  defp safe_event_value?(_key, value) when is_binary(value),
    do: String.valid?(value) and byte_size(value) <= 255

  defp safe_event_value?(_, _), do: false

  defp dependency_id_value?(value) when is_binary(value),
    do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp lease_until(now, lease_ms), do: DateTime.add(now, lease_ms, :millisecond)
  defp new_lease_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp now, do: DateTime.utc_now(:microsecond)
end
