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

    assert Repo.get!(ExecutionCapacity, 1).active == 1

    assert {:ok, _} =
             Jobs.complete(attempt, attempt.lease_token, :failed, %{error: error("worker_exit")})

    assert Repo.get!(ExecutionCapacity, 1).active == 0
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
    assert Repo.get!(ExecutionCapacity, 1).active == 0
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
    assert Repo.get!(ExecutionCapacity, 1).active == 0
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
    assert Repo.get!(ExecutionCapacity, 1).active == 0
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
    assert Repo.get!(ExecutionCapacity, 1).active == 8

    Enum.each(claims, fn attempt ->
      assert {:ok, _} =
               Jobs.complete(attempt, attempt.lease_token, :cancelled, %{
                 error: error("test_cleanup")
               })
    end)

    assert Repo.get!(ExecutionCapacity, 1).active == 0
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
    assert Repo.get!(ExecutionCapacity, 1).active == 12

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
    assert Repo.get!(ExecutionCapacity, 1).capacity == 3

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
    assert Repo.get!(ExecutionCapacity, 1).capacity == 8
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
    assert Repo.get!(ExecutionCapacity, 1).active == 0

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
    assert Repo.get!(ExecutionCapacity, 1).active == 0

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
    assert Repo.get!(ExecutionCapacity, 1).active == 2

    # The job therefore reports its live status, not a recovery-induced one.
    assert {:error, {:not_queued, "provisioning"}} = Jobs.claim(stale_job, "second-runner")

    recovery_time = DateTime.add(stale_attempt.lease_expires_at, 1, :millisecond)
    assert {:ok, 1} = Jobs.recover_stale(recovery_time)
    assert Repo.get!(Job, stale_job.id).status == "failed"
    assert Repo.get!(ExecutionCapacity, 1).active == 1
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

    assert Repo.get!(ExecutionCapacity, 1).active == 0
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
    assert Repo.get!(ExecutionCapacity, 1).active == 0

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
    assert Repo.get!(ExecutionCapacity, 1).active == 1
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

  defp load_config!(root, limits) do
    Config.load_map!(
      %{
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
