defmodule Omashiki.Jobs.WebhooksTest do
  use Omashiki.DataCase, async: false

  alias Omashiki.ApiTokens.Token
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{Job, JobAttempt, JobEvent, WebhookDelivery, Webhooks}

  setup do
    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)
    {:ok, user: user, token: token}
  end

  test "validates token destinations and rejects arbitrary callback schemes", %{token: token} do
    assert {:error, :invalid_destination_scheme} =
             Webhooks.configure(token, %{
               destination: "javascript:alert(1)",
               secret: "client-secret"
             })

    assert {:error, :private_destination_not_allowed} =
             Webhooks.configure(token, %{
               destination: "http://127.0.0.1/hook",
               secret: "client-secret"
             })

    assert {:error, :private_destination_not_allowed} =
             Webhooks.configure(token, %{
               destination: "http://[::ffff:127.0.0.1]/hook",
               secret: "client-secret"
             })

    assert {:ok, configured} =
             Webhooks.configure(token, %{
               destination: "https://client.test/hook",
               secret: "client-secret"
             })

    refute inspect(configured) =~ "client-secret"
    refute inspect(Repo.get!(Token, token.id)) =~ "client-secret"
  end

  test "canonical payload signs and rejects replayed timestamps" do
    payload = %{"b" => %{"a" => true}, "a" => 1, "timestamp" => "2026-08-24T10:00:00Z"}

    assert Webhooks.canonical_json(payload) ==
             ~s({"a":1,"b":{"a":true},"timestamp":"2026-08-24T10:00:00Z"})

    signature = Webhooks.sign(payload, "client-secret")

    assert {:ok, :valid} =
             Webhooks.verify(payload, signature, "client-secret", now: ~U[2026-08-24 10:04:00Z])

    assert {:error, :replay_or_expired} =
             Webhooks.verify(payload, signature, "client-secret", now: ~U[2026-08-24 10:05:01Z])
  end

  test "rotates keys while accepting the previous signature", %{token: token} do
    assert {:ok, _} =
             Webhooks.configure(token, %{
               destination: "https://client.test/hook",
               secret: "old-secret",
               key_id: "v1"
             })

    assert {:ok, _} =
             Webhooks.configure(token, %{
               destination: "https://client.test/hook",
               secret: "new-secret",
               key_id: "v2"
             })

    payload = %{"timestamp" => "2026-08-24T10:00:00Z", "event_id" => "event-1"}
    old_signature = Webhooks.sign(payload, "old-secret")

    assert {:ok, :valid} =
             Webhooks.verify(payload, old_signature, ["new-secret", "old-secret"],
               now: ~U[2026-08-24 10:01:00Z]
             )

    assert {:error, :invalid_signature} =
             Webhooks.verify(payload, old_signature, ["new-secret"],
               now: ~U[2026-08-24 10:01:00Z]
             )
  end

  test "terminal completion atomically creates one event and outbox row", %{
    user: user,
    token: token
  } do
    configure!(token)
    {_job, _attempt, delivery} = terminal_fixture(user, token, "succeeded")

    event = Repo.get!(JobEvent, delivery.event_id)
    assert event.status == "succeeded"
    assert delivery.idempotency_key == event.event_id
    assert delivery.payload["event_id"] == event.event_id
    assert delivery.payload["job_id"] == event.job_id
    assert delivery.payload["attempt"] == 1
    assert delivery.payload["status"] == "succeeded"
    assert delivery.payload["correlation_id"] == "webhook-correlation"
    assert delivery.payload["git"]["head_sha"] == String.duplicate("b", 40)
    refute inspect(delivery) =~ "client-secret"
  end

  test "success is delivered once and duplicate delivery is deduplicated", %{
    user: user,
    token: token
  } do
    configure!(token)
    {_job, _attempt, delivery} = terminal_fixture(user, token, "succeeded")
    test_pid = self()

    transport = fn _destination, _headers, _body ->
      send(test_pid, :sent)
      {:ok, 204}
    end

    assert {:ok, :delivered} = Webhooks.deliver(delivery.id, transport: transport)
    assert_receive :sent
    assert {:ok, :delivered} = Webhooks.deliver(delivery.id, transport: transport)
    refute_receive :sent
    assert Repo.get!(WebhookDelivery, delivery.id).status == "delivered"
  end

  test "timeouts, 4xx, and 5xx use exponential retry without reopening the job", %{
    user: user,
    token: token
  } do
    configure!(token)

    for response <- [{:error, :timeout}, {:ok, 429}, {:ok, 503}] do
      {job, _attempt, delivery} = terminal_fixture(user, token, "failed")

      assert {:retry, next_attempt_at} =
               Webhooks.deliver(delivery.id, transport: fn _, _, _ -> response end)

      assert DateTime.compare(next_attempt_at, DateTime.utc_now(:microsecond)) == :gt
      assert Repo.get!(Job, job.id).status == "failed"
    end
  end

  test "redirects are rejected rather than followed", %{user: user, token: token} do
    configure!(token)
    {_job, _attempt, delivery} = terminal_fixture(user, token, "failed")

    assert {:retry, _} = Webhooks.deliver(delivery.id, transport: fn _, _, _ -> {:ok, 302} end)
    persisted = Repo.get!(WebhookDelivery, delivery.id)
    assert persisted.last_error["code"] == "redirect_rejected"
  end

  test "duplicate outbox insertion is idempotent", %{user: user, token: token} do
    configure!(token)
    {_job, attempt, delivery} = terminal_fixture(user, token, "succeeded")
    event = Repo.get!(JobEvent, delivery.event_id)
    job = Repo.get!(Job, event.job_id)

    assert :ok = Webhooks.enqueue_for_event!(job, attempt, event)
    assert Repo.aggregate(WebhookDelivery, :count, :id) == 1
  end

  test "delivery dead-letters after the 24 hour window", %{user: user, token: token} do
    configure!(token)
    {_job, _attempt, delivery} = terminal_fixture(user, token, "failed")
    old = DateTime.add(DateTime.utc_now(:microsecond), -86_401, :second)
    Repo.update_all(WebhookDelivery, set: [inserted_at: old])

    assert {:ok, :dead} =
             Webhooks.deliver(delivery.id, transport: fn _, _, _ -> flunk("not sent") end)

    assert Repo.get!(WebhookDelivery, delivery.id).status == "dead"
  end

  test "operator status is authorized and redacted", %{user: user, token: token} do
    configure!(token)
    {job, _attempt, _delivery} = terminal_fixture(user, token, "failed")
    assert {:ok, [status]} = Webhooks.list_for_job(job.id, token)
    assert status.status == "pending"
    refute Map.has_key?(status, :payload)
    assert {:ok, [status]} = Webhooks.list_for_job(job.id, user)
    assert status.event_id
  end

  defp configure!(token) do
    assert {:ok, _} =
             Webhooks.configure(token, %{
               destination: "https://client.test/hook",
               secret: "client-secret"
             })
  end

  defp terminal_fixture(user, token, status) do
    now = DateTime.utc_now(:microsecond)

    job =
      %Job{}
      |> Job.changeset(%{
        user_id: user.id,
        api_token_id: token.id,
        idempotency_key: "webhook-#{System.unique_integer([:positive])}",
        correlation_id: "webhook-correlation",
        repository: "app",
        environment: "safe",
        payload: %{"task" => "webhook"},
        payload_hash: String.duplicate("a", 64),
        admitted_repository: %{"name" => "app"},
        admitted_repository_digest: String.duplicate("b", 64),
        admitted_environment: %{"name" => "safe"},
        admitted_environment_digest: String.duplicate("c", 64),
        registry_digest: String.duplicate("d", 64),
        queue: "default",
        priority: 0,
        status: "running",
        current_attempt: 1,
        queued_at: now,
        started_at: now
      })
      |> Repo.insert!()

    node = Omashiki.Config.current_machine().name

    Repo.update_all(
      from(c in Omashiki.Jobs.ExecutionCapacity, where: c.node_id == ^node),
      set: [active: 1]
    )

    attempt =
      %JobAttempt{}
      |> JobAttempt.changeset(%{
        job_id: job.id,
        number: 1,
        status: "running",
        lease_token: "lease",
        lease_expires_at: DateTime.add(now, 60, :second),
        heartbeat_at: now,
        claimed_at: now,
        capacity_reserved: true,
        node_id: node,
        started_at: now
      })
      |> Repo.insert!()

    attrs =
      if status == "succeeded" do
        %{
          result: %{"ok" => true},
          branch: "jobs/webhook",
          base_sha: String.duplicate("a", 40),
          head_sha: String.duplicate("b", 40),
          worktree_clean: true
        }
      else
        %{error: %{"code" => "timeout", "message" => "timed out", "details" => %{}}}
      end

    assert {:ok, %JobAttempt{}} = Jobs.complete(attempt, "lease", status, attrs)
    delivery = Repo.one!(from(d in WebhookDelivery, order_by: [desc: d.inserted_at], limit: 1))
    {Repo.get!(Job, job.id), Repo.get!(JobAttempt, attempt.id), delivery}
  end
end
