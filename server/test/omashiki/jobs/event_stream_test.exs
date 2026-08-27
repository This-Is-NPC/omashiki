defmodule Omashiki.Jobs.EventStreamTest do
  use OmashikiWeb.ConnCase, async: false

  alias Omashiki.Jobs.{EventStream, Job, JobAttempt, JobEvent}
  alias Omashiki.Repo

  test "replays strict sequence after a durable event cursor", %{token: token, user: user} do
    job = job_fixture(user, token)
    attempt = attempt_fixture(job, "queued")
    first = event_fixture(job, attempt, 1, "queued")
    _second = event_fixture(job, attempt, 2, "running")

    assert {:ok, %{after_sequence: 1}} = EventStream.prepare(job.id, token, first.event_id)
    assert {:ok, events} = EventStream.fetch_events(job.id, 1)
    assert Enum.map(events, & &1.sequence) == [2]
  end

  test "refuses to stream a persisted sequence gap", %{token: token, user: user} do
    job = job_fixture(user, token)
    attempt = attempt_fixture(job, "queued")
    _first = event_fixture(job, attempt, 1, "queued")
    _third = event_fixture(job, attempt, 3, "running")

    assert {:error, :event_gap} = EventStream.fetch_events(job.id, 1)
  end

  test "rejects invalid and cross-job cursors", %{token: token, user: user} do
    job = job_fixture(user, token)
    other_job = job_fixture(user, token)
    attempt = attempt_fixture(other_job, "queued")
    event = event_fixture(other_job, attempt, 1, "queued")

    assert {:error, :invalid_cursor} = EventStream.prepare(job.id, token, "not-a-uuid")
    assert {:error, :cursor_mismatch} = EventStream.prepare(job.id, token, event.event_id)
  end

  test "rejects a different client token even when it has the same operator", %{
    token: token,
    user: user
  } do
    {other_token, _plaintext} = api_token_fixture(user)
    job = job_fixture(user, token)

    assert {:error, :forbidden} = EventStream.prepare(job.id, other_token)
    assert {:ok, _} = EventStream.prepare(job.id, user)
  end

  test "does not replay events outside the configured retention window", %{
    token: token,
    user: user
  } do
    job = job_fixture(user, token)
    attempt = attempt_fixture(job, "queued")
    old = event_fixture(job, attempt, 1, "queued", DateTime.add(DateTime.utc_now(), -31, :day))
    current = event_fixture(job, attempt, 2, "running")

    assert {:ok, [^current]} = EventStream.fetch_events(job.id, 0)
    assert {:error, :cursor_expired} = EventStream.prepare(job.id, token, old.event_id)
  end

  test "event framing carries durable id and ordered payload", %{token: token, user: user} do
    job = job_fixture(user, token)
    attempt = attempt_fixture(job, "queued")
    event = event_fixture(job, attempt, 1, "queued")
    frame = EventStream.encode_event(event)

    assert frame =~ "id: #{event.event_id}\n"
    assert frame =~ "event: job_event\n"
    assert frame =~ ~s("sequence":1)
    assert EventStream.heartbeat_frame() == ": heartbeat\n\n"
  end

  test "heartbeat uses a bounded poll cycle for an active job", %{token: token, user: user} do
    job = job_fixture(user, token)

    conn =
      build_conn()
      |> send_chunked(200)

    conn =
      EventStream.stream(conn, %{id: job.id, status: "running"}, 0,
        heartbeat_interval_ms: 0,
        max_polls: 0
      )

    assert {_adapter, %{chunks: ": heartbeat\n\n"}} = conn.adapter
    assert conn.status == 200
  end

  test "successful terminal stream returns SSE response", %{conn: conn, token: token, user: user} do
    job = terminal_job_fixture(user, token)
    attempt = attempt_fixture(job, "succeeded")
    event = event_fixture(job, attempt, 1, "succeeded")

    conn = get(conn, ~p"/api/v1/jobs/#{job.id}/events")
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
    assert body =~ "id: #{event.event_id}"
    assert body =~ "event: job_event"
  end

  test "HTTP reconnect replays only the next strict event", %{
    token: token,
    token_plaintext: token_plaintext,
    user: user
  } do
    job = terminal_job_fixture(user, token)
    attempt = attempt_fixture(job, "succeeded")
    first = event_fixture(job, attempt, 1, "running")
    second = event_fixture(job, attempt, 2, "succeeded")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token_plaintext}")
      |> put_req_header("last-event-id", first.event_id)
      |> get(~p"/api/v1/jobs/#{job.id}/events")

    body = response(conn, 200)

    refute body =~ "id: #{first.event_id}"
    assert body =~ "id: #{second.event_id}"
    assert body =~ ~s("sequence":2)
  end

  test "cross-client HTTP access is forbidden", %{token: token, user: user} do
    {other_token, other_plaintext} = api_token_fixture(user)
    job = job_fixture(user, token)
    conn = build_conn() |> put_req_header("authorization", "Bearer #{other_plaintext}")

    conn = get(conn, ~p"/api/v1/jobs/#{job.id}/events")

    assert response(conn, 403) =~ "forbidden"
    assert other_token.id != token.id
  end

  defp job_fixture(user, token) do
    now = DateTime.utc_now(:microsecond)

    %Job{}
    |> Job.changeset(%{
      user_id: user.id,
      api_token_id: token.id,
      idempotency_key: "stream-#{System.unique_integer([:positive])}",
      correlation_id: "stream-correlation",
      repository: "app",
      environment: "safe",
      payload: %{"task" => "stream"},
      payload_hash: String.duplicate("a", 64),
      admitted_repository: %{"name" => "app"},
      admitted_repository_digest: String.duplicate("b", 64),
      admitted_environment: %{"name" => "safe"},
      admitted_environment_digest: String.duplicate("c", 64),
      registry_digest: String.duplicate("d", 64),
      queue: "default",
      priority: 0,
      status: "queued",
      current_attempt: 1,
      queued_at: now
    })
    |> Repo.insert!()
  end

  defp terminal_job_fixture(user, token) do
    job = job_fixture(user, token)
    now = DateTime.utc_now(:microsecond)

    job
    |> Job.changeset(%{
      status: "succeeded",
      started_at: now,
      finished_at: now,
      terminal_result: %{"ok" => true}
    })
    |> Repo.update!()
  end

  defp attempt_fixture(job, status) do
    now = DateTime.utc_now(:microsecond)
    attrs = %{job_id: job.id, number: 1, status: status}

    attrs =
      if status == "succeeded" do
        Map.merge(attrs, %{
          started_at: now,
          finished_at: now,
          branch: "jobs/stream",
          base_sha: String.duplicate("a", 40),
          head_sha: String.duplicate("b", 40),
          worktree_clean: true,
          result: %{"ok" => true}
        })
      else
        attrs
      end

    %JobAttempt{}
    |> JobAttempt.changeset(attrs)
    |> Repo.insert!()
  end

  defp event_fixture(job, attempt, sequence, status, recorded_at \\ nil) do
    now = recorded_at || DateTime.utc_now(:microsecond)

    %JobEvent{}
    |> JobEvent.changeset(%{
      job_id: job.id,
      attempt: attempt.number,
      sequence: sequence,
      type: "job.#{status}",
      status: status,
      step: status,
      outcome: status,
      correlation_id: job.correlation_id,
      occurred_at: now,
      recorded_at: now,
      data: %{},
      schema_version: 1
    })
    |> Repo.insert!()
  end
end
