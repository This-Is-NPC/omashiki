defmodule Omashiki.Jobs.SchemaTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.Accounts.User
  alias Omashiki.ApiTokens.Token
  alias Omashiki.Jobs.{Job, JobAttempt, JobEvent, JobStep, WebhookDelivery}
  alias Omashiki.UsageLedger.Entry

  @digest String.duplicate("a", 64)

  test "fresh schema contains only queue-owned application tables" do
    tables =
      Repo.query!("""
      SELECT tablename
      FROM pg_tables
      WHERE schemaname = 'public'
        AND tablename NOT LIKE 'oban_%'
        AND tablename <> 'schema_migrations'
      ORDER BY tablename
      """).rows
      |> List.flatten()

    assert tables ==
             ~w(api_tokens execution_capacity job_attempts job_events job_steps jobs usage_ledger users webhook_deliveries)

    oban_tables =
      Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'oban_%' ORDER BY tablename"
      ).rows
      |> List.flatten()

    assert oban_tables == ~w(oban_jobs oban_peers)
  end

  test "allows pre-start cancellation and rejects cross-owner references" do
    owner = persist_user()
    other = persist_user()
    token = persist_token(owner)

    assert {:error, token_owner_changeset} =
             %Job{} |> Job.changeset(job_attrs(other, token)) |> Repo.insert()

    assert token_owner_changeset.errors[:api_token_id]
    parent = persist_job(owner, token)

    child_attrs =
      other
      |> job_attrs(nil)
      |> Map.merge(%{
        idempotency_key: "other-request",
        parent_job_id: parent.id,
        status: "blocked",
        queued_at: nil
      })

    assert {:error, parent_changeset} = %Job{} |> Job.changeset(child_attrs) |> Repo.insert()
    assert parent_changeset.errors[:parent_job_id]

    now = DateTime.utc_now(:microsecond)

    blocked_job =
      owner
      |> job_attrs(token)
      |> Map.merge(%{
        idempotency_key: "blocked-request",
        parent_job_id: parent.id,
        status: "blocked",
        queued_at: nil
      })
      |> then(&Job.changeset(%Job{}, &1))
      |> Repo.insert!()

    blocked_cancelled =
      blocked_job
      |> Job.changeset(%{
        status: "cancelled",
        finished_at: now,
        terminal_error: %{"code" => "cancelled", "message" => "cancelled", "details" => %{}}
      })
      |> Repo.update!()

    assert is_nil(blocked_cancelled.queued_at)
    assert is_nil(blocked_cancelled.started_at)

    cancelled_job =
      parent
      |> Job.changeset(%{
        status: "cancelled",
        finished_at: now,
        terminal_error: %{"code" => "cancelled", "message" => "cancelled", "details" => %{}}
      })
      |> Repo.update!()

    assert is_nil(cancelled_job.started_at)

    attempt =
      %JobAttempt{}
      |> JobAttempt.changeset(%{job_id: parent.id, number: 1, status: "queued"})
      |> Repo.insert!()

    cancelled_attempt =
      attempt
      |> JobAttempt.changeset(%{
        status: "cancelled",
        finished_at: now,
        error: %{"code" => "cancelled", "message" => "cancelled", "details" => %{}}
      })
      |> Repo.update!()

    assert is_nil(cancelled_attempt.started_at)
    other_job = persist_job(other, nil)

    assert {:error, ledger_changeset} =
             %Entry{}
             |> Entry.changeset(%{
               request_id: "cross-owner",
               job_id: other_job.id,
               attempt_id: attempt.id,
               turn: 1,
               source: "gateway"
             })
             |> Repo.insert()

    assert ledger_changeset.errors[:attempt_id]
  end

  test "admission identity is immutable in Ecto and PostgreSQL" do
    job = persist_job(persist_user(), nil)

    changeset =
      Job.changeset(job, %{payload: %{"changed" => true}, priority: 3, status: "running"})

    refute Map.has_key?(changeset.changes, :payload)
    refute Map.has_key?(changeset.changes, :priority)
    assert changeset.changes.status == "running"

    assert [["jobs_identity_immutable"]] =
             Repo.query!(
               "SELECT tgname FROM pg_trigger WHERE tgrelid = 'jobs'::regclass AND NOT tgisinternal"
             ).rows
  end

  test "persists an immutable job snapshot and numbered attempt" do
    user = persist_user()
    token = persist_token(user)
    job = persist_job(user, token)

    assert job.admitted_repository == %{"base_branch" => "main", "name" => "app"}
    assert job.admitted_environment == %{"name" => "opencode"}

    attempt =
      %JobAttempt{}
      |> JobAttempt.changeset(%{job_id: job.id, number: 1, status: "queued"})
      |> Repo.insert!()

    %JobStep{}
    |> JobStep.changeset(%{
      attempt_id: attempt.id,
      sequence: 1,
      key: "pre-1",
      kind: "pre",
      status: "pending"
    })
    |> Repo.insert!()

    now = DateTime.utc_now(:microsecond)

    event =
      %JobEvent{}
      |> JobEvent.changeset(%{
        job_id: job.id,
        attempt: 1,
        sequence: 1,
        type: "job.queued",
        status: "queued",
        step: "queued",
        outcome: "queued",
        correlation_id: job.correlation_id,
        occurred_at: now,
        recorded_at: now,
        data: %{}
      })
      |> Repo.insert!()

    delivery =
      %WebhookDelivery{}
      |> WebhookDelivery.changeset(%{
        event_id: event.event_id,
        destination: "https://client.test/jobs",
        idempotency_key: event.event_id,
        status: "pending",
        attempts: 0,
        next_attempt_at: now,
        payload: %{"event_id" => event.event_id},
        payload_hash: @digest
      })
      |> Repo.insert!()

    assert delivery.event_id == event.event_id

    usage =
      %Entry{}
      |> Entry.changeset(%{
        request_id: "provider-request-1",
        job_id: job.id,
        attempt_id: attempt.id,
        turn: 1,
        source: "gateway",
        provider: "openai",
        model: "gpt",
        input_tokens: 10,
        output_tokens: 5
      })
      |> Repo.insert!()

    assert usage.job_id == job.id
    assert usage.attempt_id == attempt.id
  end

  test "enforces idempotency, attempt numbers, event sequence, and terminal shape" do
    user = persist_user()
    job = persist_job(user, nil)

    duplicate = Job.changeset(%Job{}, job_attrs(user, nil))
    assert {:error, changeset} = Repo.insert(duplicate)
    assert %{user_id: [_ | _]} = errors_on(changeset)

    attempt =
      %JobAttempt{}
      |> JobAttempt.changeset(%{job_id: job.id, number: 1, status: "queued"})
      |> Repo.insert!()

    assert {:error, duplicate_attempt} =
             %JobAttempt{}
             |> JobAttempt.changeset(%{job_id: job.id, number: 1, status: "queued"})
             |> Repo.insert()

    assert duplicate_attempt.errors[:job_id]

    now = DateTime.utc_now(:microsecond)

    %JobEvent{}
    |> JobEvent.changeset(%{
      job_id: job.id,
      attempt: attempt.number,
      sequence: 1,
      type: "job.queued",
      status: "queued",
      step: "queued",
      outcome: "queued",
      correlation_id: job.correlation_id,
      occurred_at: now,
      recorded_at: now,
      data: %{}
    })
    |> Repo.insert!()

    assert {:error, duplicate_event} =
             %JobEvent{}
             |> JobEvent.changeset(%{
               job_id: job.id,
               attempt: attempt.number,
               sequence: 1,
               type: "job.queued",
               status: "queued",
               step: "queued",
               outcome: "queued",
               correlation_id: job.correlation_id,
               occurred_at: now,
               recorded_at: now,
               data: %{}
             })
             |> Repo.insert()

    assert duplicate_event.errors[:job_id]

    invalid_success =
      JobAttempt.changeset(attempt, %{
        status: "succeeded",
        started_at: now,
        finished_at: now,
        branch: "omashiki/job-test",
        result: %{"ok" => true}
      })

    assert {:error, terminal_changeset} = Repo.update(invalid_success)
    assert terminal_changeset.errors[:status]

    non_git_success =
      JobAttempt.changeset(attempt, %{
        status: "succeeded",
        started_at: now,
        finished_at: now,
        result: %{"ok" => true}
      })

    assert {:ok, _} = Repo.update(non_git_success)
  end

  test "declares queue, outbox, and retention indexes" do
    indexes =
      Repo.query!("SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public'").rows
      |> Map.new(fn [name, definition] -> {name, definition} end)

    for name <- ~w(
      jobs_queue_order_index
       jobs_finished_at_index
       job_attempts_one_active_per_job
       job_attempts_expired_leases_index
       job_attempts_finished_at_index
      job_events_occurred_at_index
      webhook_deliveries_outbox_index
      webhook_deliveries_inserted_at_index
      usage_ledger_occurred_at_index
    ) do
      assert Map.has_key?(indexes, name)
    end

    assert indexes["jobs_queue_order_index"] =~ "priority DESC"
    assert indexes["jobs_queue_order_index"] =~ "WHERE (status = 'queued'::text)"
    assert indexes["webhook_deliveries_outbox_index"] =~ "WHERE (status = ANY"

    for name <-
          ~w(jobs_finished_at_index job_attempts_finished_at_index job_events_occurred_at_index webhook_deliveries_inserted_at_index usage_ledger_occurred_at_index) do
      assert indexes[name] =~ "USING brin"
    end

    assert [{Oban.Plugins.Pruner, options}, {Oban.Plugins.Lifeline, lifeline}] =
             Application.fetch_env!(:omashiki, Oban)[:plugins]

    assert options[:max_age] == 60 * 60 * 24 * 30

    # Lifeline is what reclaims a dispatch orphaned in `executing` by a dead
    # node; `Jobs.recover_orphaned_dispatches/1` deliberately leaves those rows
    # alone because `executing` is an incomplete state. `rescue_after` has to
    # stay above the longest legitimate run (harness `timeout_ms` is 30 min plus
    # pre-steps) or a live attempt gets rescued out from under itself.
    assert lifeline[:rescue_after] >= :timer.minutes(60)
  end

  defp persist_user do
    Repo.insert!(%User{
      email: "owner-#{System.unique_integer([:positive])}@example.test",
      username: "owner-#{System.unique_integer([:positive])}",
      password_hash: "argon2"
    })
  end

  defp persist_token(user) do
    %Token{}
    |> Token.create_changeset(%{
      user_id: user.id,
      name: "automation",
      token_hash: String.duplicate("b", 64)
    })
    |> Repo.insert!()
  end

  defp persist_job(user, token) do
    %Job{}
    |> Job.changeset(job_attrs(user, token))
    |> Repo.insert!()
  end

  defp job_attrs(user, token) do
    %{
      user_id: user.id,
      api_token_id: token && token.id,
      idempotency_key: "request-1",
      correlation_id: "correlation-1",
      repository: "app",
      environment: "opencode",
      payload: %{"instruction" => "run"},
      payload_hash: @digest,
      admitted_repository: %{"name" => "app", "base_branch" => "main"},
      admitted_repository_digest: @digest,
      admitted_environment: %{"name" => "opencode"},
      admitted_environment_digest: @digest,
      admitted_plugin: %{"path" => "plugins/opencode.toml", "contents" => "", "digest" => String.duplicate("e", 64)},
      admitted_plugin_digest: String.duplicate("e", 64),
      registry_digest: @digest,
      queue: "default",
      priority: 0,
      status: "queued",
      current_attempt: 1,
      queued_at: DateTime.utc_now(:microsecond)
    }
  end
end
