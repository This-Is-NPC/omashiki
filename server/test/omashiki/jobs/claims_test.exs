defmodule Omashiki.Jobs.ClaimsTest do
  use Omashiki.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{ExecutionCapacity, Job, JobAttempt, JobEvent}
  alias Omashiki.Repo

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-claims-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])

    load_config!(root, %{})

    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, token: token}
  end

  test "concurrent claims fence one active attempt", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("fenced"))

    results =
      Task.async_stream(1..2, fn n -> Jobs.claim(job, "runner-#{n}") end, max_concurrency: 2)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, attempt}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, {:not_queued, "provisioning"}}, &1)) == 1

    assert Repo.aggregate(
             from(a in JobAttempt,
               where: a.job_id == ^job.id and a.status in ["provisioning", "running"]
             ),
             :count,
             :id
           ) == 1

    assert capacity_row().active == 1

    assert {:ok, _} =
             Jobs.complete(attempt, attempt.lease_token, :failed, %{error: error("worker_exit")})

    assert capacity_row().active == 0
  end

  # The production caller is `DispatchWorker`, which passes only a runner id
  # (`"oban:<id>"` — the dispatch job, not the machine). The node has to come
  # from the claim path's own view of this host, or it is never recorded at all.
  test "a claim records the declared node that ran the attempt", %{root: root, token: token} do
    load_config!(root, %{}, %{"builder-01" => %{}})
    # Boot order: config, then the node's own capacity row. A node with no row
    # has no budget and claims nothing, so the claim below would fail for a
    # reason that has nothing to do with what this test asserts.
    assert {:ok, _} = Jobs.sync_capacity()
    {:ok, job} = Jobs.Admission.admit(token, request("declared-node"))

    assert {:ok, attempt} = Jobs.claim(job, "oban:1")
    assert attempt.node_id == "builder-01"
    assert Repo.get!(JobAttempt, attempt.id).node_id == "builder-01"

    # The dedicated column, not an overloaded runner id.
    assert attempt.runner_id == "oban:1"
  end

  # The compatibility path: no `[nodes]` section at all still answers "which
  # machine ran this?", because there is one implicit local node.
  test "a claim with no declared nodes records the implicit local node", %{
    root: root,
    token: token
  } do
    previous = System.get_env("OMASHIKI_NODE")
    System.put_env("OMASHIKI_NODE", "implicit-claim-host")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("OMASHIKI_NODE")
        value -> System.put_env("OMASHIKI_NODE", value)
      end
    end)

    load_config!(root, %{})
    assert {:ok, _} = Jobs.sync_capacity()
    refute Enum.any?(Config.nodes(), &(&1.name == "builder-01"))
    {:ok, job} = Jobs.Admission.admit(token, request("implicit-node"))

    assert {:ok, attempt} = Jobs.claim(job, "oban:2")
    assert attempt.node_id == "implicit-claim-host"
  end

  test "worker crash before claim leaves the job queued without capacity", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("crash-before-claim"))
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, :before_claim)
        exit(:simulated_crash)
      end)

    assert_receive :before_claim
    assert_receive {:DOWN, ^ref, :process, ^pid, :simulated_crash}
    assert Repo.get!(Job, job.id).status == "queued"
    assert capacity_row().active == 0
  end

  test "worker crash during provisioning is recovered once", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("crash-provisioning"))
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:sandbox_ready, self()})

        receive do
          :go -> :ok
        end

        {:ok, attempt} = Jobs.claim(job, "provisioning-crash", lease_ms: 1)
        send(parent, {:provisioning_claimed, attempt})
        exit(:simulated_crash)
      end)

    assert_receive {:sandbox_ready, ^pid}
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    send(pid, :go)

    assert_receive {:provisioning_claimed, attempt}
    assert_receive {:DOWN, ^ref, :process, ^pid, :simulated_crash}
    assert {:ok, 1} = Jobs.recover_stale(DateTime.add(attempt.lease_expires_at, 1, :millisecond))
    assert {:ok, 0} = Jobs.recover_stale(DateTime.add(attempt.lease_expires_at, 1, :millisecond))
    assert Repo.get!(Job, job.id).status == "failed"
    assert capacity_row().active == 0
  end

  test "worker crash during execution is recovered once", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("crash-execution"))
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:sandbox_ready, self()})

        receive do
          :go -> :ok
        end

        {:ok, attempt} = Jobs.claim(job, "execution-crash")
        {:ok, _running} = Jobs.mark_running(attempt, attempt.lease_token)
        send(parent, {:execution_started, attempt})
        exit(:simulated_crash)
      end)

    assert_receive {:sandbox_ready, ^pid}
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    send(pid, :go)

    assert_receive {:execution_started, attempt}
    assert_receive {:DOWN, ^ref, :process, ^pid, :simulated_crash}
    assert {:ok, 1} = Jobs.recover_stale(DateTime.add(attempt.lease_expires_at, 1, :millisecond))
    assert Repo.get!(Job, job.id).status == "failed"
    assert capacity_row().active == 0
  end

  test "heartbeat and running transition reject a stale fencing token", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("heartbeat"))
    {:ok, attempt} = Jobs.claim(job, "heartbeat-runner")

    assert {:error, :stale_lease} = Jobs.heartbeat(attempt, "wrong-token")
    assert {:ok, refreshed} = Jobs.heartbeat(attempt, attempt.lease_token)
    assert refreshed.lease_token == attempt.lease_token
    assert {:error, :stale_lease} = Jobs.mark_running(attempt, "wrong-token")
    assert {:ok, %Job{status: "running"}} = Jobs.mark_running(attempt, attempt.lease_token)
  end

  test "global capacity admits exactly eight concurrent containers", %{token: token} do
    jobs =
      Enum.map(1..9, fn n ->
        {:ok, job} = Jobs.Admission.admit(token, request("capacity-#{n}"))
        job
      end)

    results =
      Task.async_stream(jobs, fn job -> Jobs.claim(job, "capacity-runner-#{job.id}") end,
        max_concurrency: 9,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    claims =
      Enum.flat_map(results, fn
        {:ok, attempt} -> [attempt]
        _ -> []
      end)

    assert length(claims) == 8
    assert Enum.count(results, &match?({:error, :capacity_exhausted}, &1)) == 1
    assert capacity_row().active == 8

    Enum.each(claims, fn attempt ->
      assert {:ok, _} =
               Jobs.complete(attempt, attempt.lease_token, :cancelled, %{
                 error: error("test_cleanup")
               })
    end)

    assert capacity_row().active == 0
  end

  test "declared max_concurrent_containers raises the budget past the seeded default", %{
    root: root,
    token: token
  } do
    load_config!(root, %{"max_concurrent_containers" => 12})
    assert {:ok, %ExecutionCapacity{capacity: 12}} = Jobs.sync_capacity()

    jobs =
      Enum.map(1..13, fn n ->
        {:ok, job} = Jobs.Admission.admit(token, request("raised-#{n}"))
        job
      end)

    results =
      Task.async_stream(jobs, fn job -> Jobs.claim(job, "raised-runner-#{job.id}") end,
        max_concurrency: 13,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    claims =
      Enum.flat_map(results, fn
        {:ok, attempt} -> [attempt]
        _ -> []
      end)

    assert length(claims) == 12
    assert Enum.count(results, &match?({:error, :capacity_exhausted}, &1)) == 1
    assert capacity_row().active == 12

    Enum.each(claims, fn attempt ->
      assert {:ok, _} =
               Jobs.complete(attempt, attempt.lease_token, :cancelled, %{
                 error: error("test_cleanup")
               })
    end)
  end

  test "lowering the declared budget clamps to outstanding reservations", %{
    root: root,
    token: token
  } do
    load_config!(root, %{"max_concurrent_containers" => 4})
    assert {:ok, %ExecutionCapacity{capacity: 4}} = Jobs.sync_capacity()

    attempts =
      Enum.map(1..3, fn n ->
        {:ok, job} = Jobs.Admission.admit(token, request("clamp-#{n}"))
        {:ok, attempt} = Jobs.claim(job, "clamp-runner-#{n}")
        attempt
      end)

    load_config!(root, %{"max_concurrent_containers" => 1})

    log =
      capture_log(fn ->
        assert {:ok, %ExecutionCapacity{capacity: 3}} = Jobs.sync_capacity()
      end)

    assert log =~ "execution capacity held at 3"
    assert capacity_row().capacity == 3

    Enum.each(attempts, fn attempt ->
      assert {:ok, _} =
               Jobs.complete(attempt, attempt.lease_token, :cancelled, %{
                 error: error("test_cleanup")
               })
    end)
  end

  test "set_capacity rejects a non-positive budget" do
    assert {:error, :invalid_capacity} = Jobs.set_capacity(0)
    assert {:error, :invalid_capacity} = Jobs.set_capacity(-1)
    assert {:error, :invalid_capacity} = Jobs.set_capacity("12")
    assert capacity_row().capacity == 8
  end

  test "cancellation is idempotent in blocked queued provisioning and running states", %{
    token: token
  } do
    {:ok, [parent, blocked]} = Jobs.Admission.admit_batch(token, batch_request())
    assert {:ok, _} = Jobs.cancel(blocked)
    assert {:ok, same_blocked} = Jobs.cancel(blocked)
    assert same_blocked.status == "cancelled"

    {:ok, queued} = Jobs.Admission.admit(token, request("queued-cancel"))
    assert {:ok, _} = Jobs.cancel(queued)
    assert {:ok, _} = Jobs.cancel(queued)

    {:ok, provisioning} = Jobs.Admission.admit(token, request("provisioning-cancel"))
    {:ok, provisioning_attempt} = Jobs.claim(provisioning, "provisioning-runner")
    assert {:ok, _} = Jobs.cancel(provisioning)
    assert {:ok, _} = Jobs.cancel(provisioning)
    assert provisioning_attempt.status == "provisioning"

    {:ok, running} = Jobs.Admission.admit(token, request("running-cancel"))
    {:ok, running_attempt} = Jobs.claim(running, "running-runner")
    assert {:ok, _} = Jobs.mark_running(running_attempt, running_attempt.lease_token)
    assert {:ok, _} = Jobs.cancel(running)
    assert {:ok, _} = Jobs.cancel(running)

    assert Repo.get!(Job, parent.id).status == "queued"
    assert capacity_row().active == 0

    for job <- [blocked, queued, provisioning, running] do
      assert Repo.aggregate(
               from(e in JobEvent, where: e.job_id == ^job.id and e.status == "cancelled"),
               :count,
               :event_id
             ) == 1
    end
  end

  test "retry preserves the job and numbers attempts after cancellation", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("retry-number"))
    assert {:ok, _} = Jobs.cancel(job)
    assert {:ok, retried} = Jobs.retry(job)
    assert retried.id == job.id
    assert retried.current_attempt == 2
    assert Repo.get_by!(JobAttempt, job_id: job.id, number: 1).status == "cancelled"
    assert Repo.get_by!(JobAttempt, job_id: job.id, number: 2).status == "queued"

    assert {:ok, _} = Jobs.cancel(retried)
    assert {:ok, retried_again} = Jobs.retry(retried)
    assert retried_again.current_attempt == 3
  end

  test "stale recovery is deterministic after a worker exits after claim", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("stale-recovery"))

    task =
      Task.async(fn ->
        {:ok, attempt} = Jobs.claim(job, "crashed-runner", lease_ms: 1)
        attempt
      end)

    attempt = Task.await(task)
    recovery_time = DateTime.add(attempt.lease_expires_at, 1, :millisecond)
    assert {:ok, 1} = Jobs.recover_stale(recovery_time)
    assert {:ok, 0} = Jobs.recover_stale(recovery_time)
    assert Repo.get!(Job, job.id).status == "failed"
    assert capacity_row().active == 0

    assert Repo.aggregate(
             from(e in JobEvent, where: e.job_id == ^job.id and e.status == "failed"),
             :count,
             :event_id
           ) == 1
  end

  test "claiming never reclaims an expired attempt inline", %{token: token} do
    {:ok, stale_job} = Jobs.Admission.admit(token, request("stale-holder"))
    {:ok, stale_attempt} = Jobs.claim(stale_job, "stale-runner", lease_ms: 1)
    Process.sleep(5)
    assert DateTime.compare(DateTime.utc_now(), stale_attempt.lease_expires_at) == :gt

    {:ok, fresh_job} = Jobs.Admission.admit(token, request("fresh-claimer"))
    assert {:ok, _fresh_attempt} = Jobs.claim(fresh_job, "fresh-runner")

    # `Jobs.Recovery` is the sole owner of stale reclamation: the claim above
    # must leave the expired attempt, its job, and its reserved slot untouched.
    assert Repo.get!(Job, stale_job.id).status == "provisioning"
    assert Repo.get!(JobAttempt, stale_attempt.id).status == "provisioning"
    assert capacity_row().active == 2

    # The job therefore reports its live status, not a recovery-induced one.
    assert {:error, {:not_queued, "provisioning"}} = Jobs.claim(stale_job, "second-runner")

    recovery_time = DateTime.add(stale_attempt.lease_expires_at, 1, :millisecond)
    assert {:ok, 1} = Jobs.recover_stale(recovery_time)
    assert Repo.get!(Job, stale_job.id).status == "failed"
    assert capacity_row().active == 1
  end

  test "repeated terminal completion has one effect", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("terminal-race"))
    {:ok, attempt} = Jobs.claim(job, "terminal-runner")

    results =
      Task.async_stream(
        1..3,
        fn _ -> Jobs.complete(attempt, attempt.lease_token, :succeeded, success_attrs()) end,
        max_concurrency: 3
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))

    assert Repo.aggregate(
             from(e in JobEvent, where: e.job_id == ^job.id and e.status == "succeeded"),
             :count,
             :event_id
           ) == 1

    assert capacity_row().active == 0
  end

  test "a second terminal outcome is a no-op for the same attempt", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("terminal-conflict"))
    {:ok, attempt} = Jobs.claim(job, "terminal-conflict-runner")

    assert {:ok, %JobAttempt{status: "failed"}} =
             Jobs.complete(attempt, attempt.lease_token, :failed, %{error: error("worker_exit")})

    assert {:ok, same_attempt} =
             Jobs.complete(attempt, "wrong-token", :cancelled, %{error: error("cancelled")})

    assert same_attempt.status == "failed"
    assert Repo.get!(Job, job.id).status == "failed"
    assert capacity_row().active == 0

    assert Repo.aggregate(
             from(e in JobEvent,
               where: e.job_id == ^job.id and e.status in ["failed", "cancelled"]
             ),
             :count,
             :event_id
           ) == 1
  end

  test "terminal persistence faults roll back the whole projection", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("terminal-fault"))
    {:ok, attempt} = Jobs.claim(job, "terminal-fault-runner")

    assert {:error, {:persistence, %Ecto.Changeset{}}} =
             Jobs.complete(
               attempt,
               attempt.lease_token,
               :succeeded,
               success_attrs() |> Map.put(:head_sha, "not-a-git-sha")
             )

    assert Repo.get!(Job, job.id).status == "provisioning"
    assert Repo.get!(JobAttempt, attempt.id).status == "provisioning"
    assert capacity_row().active == 1
    assert Repo.aggregate(from(e in JobEvent, where: e.job_id == ^job.id), :count, :event_id) == 2

    assert {:ok, %JobAttempt{status: "succeeded"}} =
             Jobs.complete(attempt, attempt.lease_token, :succeeded, success_attrs())
  end

  test "job events carry ordered identity and sanitized terminal attributes", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("event-shape"))
    {:ok, attempt} = Jobs.claim(job, "event-shape-runner")

    assert {:ok, _} = Jobs.complete(attempt, attempt.lease_token, :succeeded, success_attrs())

    events = Repo.all(from(e in JobEvent, where: e.job_id == ^job.id, order_by: e.sequence))

    assert Enum.map(events, & &1.sequence) == [1, 2, 3]
    assert Enum.all?(events, &(&1.attempt == 1))
    assert Enum.all?(events, &(&1.step == &1.outcome))
    assert Enum.all?(events, &(&1.correlation_id == job.correlation_id))

    terminal = List.last(events)
    assert terminal.status == "succeeded"

    assert terminal.data == %{
             "base_sha" => String.duplicate("a", 40),
             "branch" => "jobs/terminal",
             "head_sha" => String.duplicate("b", 40)
           }

    refute Map.has_key?(terminal.data, "result")
    refute Map.has_key?(terminal.data, "token")
  end

  test "a succeeded job is irreversible and cannot create another attempt", %{token: token} do
    {:ok, job} = Jobs.Admission.admit(token, request("irreversible"))
    {:ok, attempt} = Jobs.claim(job, "irreversible-runner")

    assert {:ok, %JobAttempt{status: "succeeded"}} =
             Jobs.complete(attempt, attempt.lease_token, :succeeded, success_attrs())

    assert {:error, {:invalid_transition, "succeeded", "queued"}} = Jobs.retry(job)
    assert Repo.aggregate(from(a in JobAttempt, where: a.job_id == ^job.id), :count, :id) == 1
  end

  describe "orphaned dispatch recovery" do
    test "a discarded dispatch cancels both the job row and its queued attempt", %{token: token} do
      {:ok, job} = Jobs.Admission.admit(token, request("orphan-discarded"))

      # The premise this sweep is built on: admission leaves an attempt behind.
      assert %JobAttempt{number: 1, status: "queued"} = current_attempt(job)
      assert Repo.get!(Job, job.id).status == "queued"

      discard_dispatch!(job.id)

      # `recover_stale/1` is blind to this: it only scans attempts in
      # `provisioning`/`running`, and this attempt is still `queued`.
      assert {:ok, 0} = Jobs.recover_stale(past_grace())
      assert Repo.get!(Job, job.id).status == "queued"

      assert {:ok, 1} = Jobs.recover_orphaned_dispatches(past_grace())

      # Both rows, not just the job row.
      assert %Job{status: "cancelled", finished_at: %DateTime{}, terminal_error: job_error} =
               Repo.get!(Job, job.id)

      assert job_error["code"] == "orphaned_dispatch"

      assert %JobAttempt{
               number: 1,
               status: "cancelled",
               finished_at: %DateTime{},
               error: attempt_error,
               capacity_reserved: false,
               lease_token: nil,
               lease_expires_at: nil
             } = current_attempt(job)

      assert attempt_error["code"] == "orphaned_dispatch"

      # No attempt of this job is left in a non-terminal state.
      assert Repo.aggregate(
               from(a in JobAttempt,
                 where:
                   a.job_id == ^job.id and a.status not in ["succeeded", "failed", "cancelled"]
               ),
               :count,
               :id
             ) == 0

      assert Repo.aggregate(
               from(e in JobEvent, where: e.job_id == ^job.id and e.status == "cancelled"),
               :count,
               :event_id
             ) == 1
    end

    test "the sweep is idempotent and releases no capacity it never held", %{token: token} do
      {:ok, job} = Jobs.Admission.admit(token, request("orphan-idempotent"))
      discard_dispatch!(job.id)

      assert {:ok, 1} = Jobs.recover_orphaned_dispatches(past_grace())
      assert {:ok, 0} = Jobs.recover_orphaned_dispatches(past_grace())

      # A queued job never reserved a slot, so recovery must not release one.
      assert capacity_row().active == 0
    end

    test "a job whose dispatch was pruned away entirely is recovered", %{token: token} do
      {:ok, job} = Jobs.Admission.admit(token, request("orphan-pruned"))
      {1, _} = Repo.delete_all(dispatch_query(job.id))

      assert {:ok, 1} = Jobs.recover_orphaned_dispatches(past_grace())
      assert Repo.get!(Job, job.id).status == "cancelled"
      assert %JobAttempt{status: "cancelled"} = current_attempt(job)
    end

    for state <- ~w(available scheduled retryable executing) do
      test "a dispatch still #{state} is left alone", %{token: token} do
        {:ok, job} = Jobs.Admission.admit(token, request("orphan-live-#{unquote(state)}"))
        set_dispatch_state!(job.id, unquote(state))

        assert {:ok, 0} = Jobs.recover_orphaned_dispatches(past_grace())
        assert Repo.get!(Job, job.id).status == "queued"
        assert %JobAttempt{status: "queued"} = current_attempt(job)
      end
    end

    test "a freshly admitted job is protected by the grace period", %{token: token} do
      {:ok, job} = Jobs.Admission.admit(token, request("orphan-grace"))
      discard_dispatch!(job.id)

      # Inside the grace window nothing is touched, even with no live dispatch.
      assert {:ok, 0} = Jobs.recover_orphaned_dispatches(DateTime.utc_now())
      assert Repo.get!(Job, job.id).status == "queued"

      assert {:ok, 1} = Jobs.recover_orphaned_dispatches(past_grace())
      assert Repo.get!(Job, job.id).status == "cancelled"
    end

    test "a claimed job is never swept, even with its dispatch discarded", %{token: token} do
      {:ok, job} = Jobs.Admission.admit(token, request("orphan-claimed"))
      {:ok, _attempt} = Jobs.claim(job, "orphan-runner")
      discard_dispatch!(job.id)

      # Past `queued` the row belongs to the lease, and so to `recover_stale/1`.
      assert {:ok, 0} = Jobs.recover_orphaned_dispatches(past_grace())
      assert Repo.get!(Job, job.id).status == "provisioning"

      assert {:ok, _} = Jobs.cancel(job)
      assert capacity_row().active == 0
    end

    test "one Recovery tick runs the orphan sweep alongside the stale sweep", %{token: token} do
      {:ok, job} = Jobs.Admission.admit(token, request("orphan-tick"))
      discard_dispatch!(job.id)

      # Age the row out of the grace window so a tick using the real clock sees
      # it, then drive exactly one tick of the GenServer that owns both sweeps.
      backdate_queued_at!(job.id, 120)

      assert {:noreply, nil} = Jobs.Recovery.handle_info(:recover, nil)

      assert Repo.get!(Job, job.id).status == "cancelled"
      assert %JobAttempt{status: "cancelled"} = current_attempt(job)
    end

    test "several stranded jobs are recovered in one pass, oldest first", %{token: token} do
      jobs =
        Enum.map(1..3, fn n ->
          {:ok, job} = Jobs.Admission.admit(token, request("orphan-batch-#{n}"))
          discard_dispatch!(job.id)
          job
        end)

      assert {:ok, 3} = Jobs.recover_orphaned_dispatches(past_grace())

      for job <- jobs do
        assert Repo.get!(Job, job.id).status == "cancelled"
        assert %JobAttempt{status: "cancelled"} = current_attempt(job)
      end

      # The drain condition the load test asserts: nothing left non-terminal.
      ids = Enum.map(jobs, & &1.id)

      assert Repo.aggregate(
               from(j in Job,
                 where: j.id in ^ids and j.status not in ["succeeded", "failed", "cancelled"]
               ),
               :count,
               :id
             ) == 0
    end

    test "a cancelled dispatch is swept, since Oban will never run it", %{token: token} do
      {:ok, job} = Jobs.Admission.admit(token, request("orphan-cancelled"))
      set_dispatch_state!(job.id, "cancelled")

      assert {:ok, 1} = Jobs.recover_orphaned_dispatches(past_grace())
      assert Repo.get!(Job, job.id).status == "cancelled"
      assert %JobAttempt{status: "cancelled"} = current_attempt(job)
    end
  end

  defp current_attempt(%Job{} = job) do
    job = Repo.get!(Job, job.id)

    Repo.one!(
      from(a in JobAttempt, where: a.job_id == ^job.id and a.number == ^job.current_attempt)
    )
  end

  defp dispatch_query(job_id) do
    from(o in Oban.Job,
      where:
        o.worker == "Omashiki.Jobs.DispatchWorker" and
          fragment("(?->>'job_id')", o.args) == ^job_id
    )
  end

  defp discard_dispatch!(job_id), do: set_dispatch_state!(job_id, "discarded")

  defp set_dispatch_state!(job_id, state) do
    {1, _} =
      Repo.update_all(dispatch_query(job_id),
        set: [state: state, discarded_at: nil, cancelled_at: nil]
      )

    :ok
  end

  # The sweep holds stranded rows for a grace period; look at the world from far
  # enough in the future that the window has closed.
  defp past_grace, do: DateTime.add(DateTime.utc_now(), 60, :second)

  # The inverse of `past_grace/0`, for the paths that must use the real clock.
  defp backdate_queued_at!(job_id, seconds) do
    {1, _} =
      Repo.update_all(from(j in Job, where: j.id == ^job_id),
        set: [queued_at: DateTime.add(DateTime.utc_now(), -seconds, :second)]
      )

    :ok
  end

  defp load_config!(root, limits, nodes \\ %{}) do
    Config.load_map!(
      %{
        "nodes" => nodes,
        "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
        "harnesses" => %{
          "opencode" => %{
            "adapter" => "opencode",
            "runtime" => "docker",
            "image" => "agent:latest"
          }
        },
        "environments" => %{
          "safe" => %{
            "harness" => "opencode",
            "executables" => ["git"],
            "timeout_ms" => 1_000,
            "caches" => [],
            "mounts" => [],
            "pre_steps" => [],
            "post_steps" => [],
            "policy" => %{"mode" => "off"},
            "network" => "none",
            "resources" => %{"cpus" => 1, "memory" => "1GB", "pids" => 32}
          }
        },
        "limits" => limits
      },
      path: Path.join(root, "omashiki.toml")
    )
  end

  defp request(key) do
    %{
      "schema_version" => 1,
      "idempotency_key" => key,
      "correlation_id" => "correlation-#{key}",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{"instruction" => "run", "context" => %{"key" => key}},
      "priority" => 0
    }
  end

  defp batch_request do
    %{
      "schema_version" => 1,
      "correlation_id" => "cancel-batch",
      "jobs" => [batch_job("parent"), batch_job("blocked", "parent")]
    }
  end

  defp batch_job(ref, parent_ref \\ nil) do
    job = %{
      "ref" => ref,
      "idempotency_key" => "batch-#{ref}",
      "repo" => "app",
      "environment" => "safe",
      "payload" => %{"instruction" => "run", "context" => %{"ref" => ref}},
      "priority" => 0
    }

    if parent_ref, do: Map.put(job, "parent_ref", parent_ref), else: job
  end

  defp error(code), do: %{"code" => code, "message" => code, "details" => %{}}

  defp success_attrs do
    %{
      branch: "jobs/terminal",
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      worktree_clean: true,
      result: %{"ok" => true}
    }
  end
end
