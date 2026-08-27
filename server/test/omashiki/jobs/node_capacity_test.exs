defmodule Omashiki.Jobs.NodeCapacityTest do
  @moduledoc """
  Per-node execution capacity.

  ## What "two nodes" means here

  There is one machine and one BEAM. A node is `Config.current_machine/0`, which
  lives in `:persistent_term` and is therefore global to the VM, so these tests
  *become* one node at a time rather than running two at once. Every assertion
  below still goes through the real `reserve_capacity!`, `release_capacity!`,
  `sync_capacity/0` and `recover_stale/1` against two distinct `machine_id` rows in
  one Postgres — the code path is genuine, the concurrency between two hosts is
  not.

  Specifically this does **not** cover: two operating-system processes racing on
  the same row (Postgres serializes the compare-and-swap, and `claims_test`
  covers same-node concurrency), network partitions, clock skew between hosts,
  or a node dying mid-transaction. "Killing a node" is modelled as its leases
  expiring and another node sweeping them, which is what the survivor actually
  observes.
  """

  use Omashiki.DataCase, async: false

  import Ecto.Query

  alias Omashiki.Config
  alias Omashiki.Jobs
  alias Omashiki.Jobs.{ExecutionCapacity, Job, JobAttempt}
  alias Omashiki.Repo

  @nodes %{"node-a" => %{}, "node-b" => %{}}

  setup do
    root = Path.join(System.tmp_dir!(), "omashiki-node-cap-#{System.unique_integer([:positive])}")
    repo_path = Path.join(root, "repo")
    File.mkdir_p!(repo_path)
    {_, 0} = System.cmd("git", ["-C", repo_path, "init", "-q"])

    previous = System.get_env("OMASHIKI_NODE")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("OMASHIKI_NODE")
        value -> System.put_env("OMASHIKI_NODE", value)
      end

      File.rm_rf!(root)
    end)

    # The schema ships one row, `'local'`, for the single machine a pre-node
    # install ran on. These tests describe a cluster that machine is not in, and
    # `cluster_capacity/0` sums whatever rows exist, so drop it rather than
    # carry an eighth node nobody declared through every total.
    Repo.delete_all(from(c in ExecutionCapacity, where: c.node_id == "local"))

    user = user_fixture()
    {token, _plaintext} = api_token_fixture(user)
    {:ok, root: root, token: token}
  end

  test "each node reconciles only its own row", %{root: root} do
    boot!(root, "node-a", 10)
    boot!(root, "node-b", 10)

    assert row("node-a").capacity == 10
    assert row("node-b").capacity == 10

    # The bug this whole change exists for: before the re-key both boots wrote
    # the same row, so the second node silently redefined the first node's
    # budget. Lower node-b and node-a must not move.
    boot!(root, "node-b", 3)

    assert row("node-a").capacity == 10
    assert row("node-b").capacity == 3
  end

  test "a node with no capacity row claims nothing until boot gives it one", %{
    root: root,
    token: token
  } do
    become!(root, "node-a")
    {:ok, job} = Jobs.Admission.admit(token, request("unbooted"))

    assert Repo.get(ExecutionCapacity, "node-a") == nil
    assert {:error, :capacity_exhausted} = Jobs.claim(job, "runner-1")

    assert {:ok, _} = Jobs.sync_capacity()
    assert {:ok, attempt} = Jobs.claim(job, "runner-1")
    assert attempt.machine_id == "node-a"
    assert row("node-a").active == 1
  end

  # DONE WHEN, part one: two nodes at 10 each run 20 attempts, and neither
  # node's ceiling is the other's.
  test "twenty attempts run across two nodes at ten slots each", %{root: root, token: token} do
    boot!(root, "node-a", 10)
    boot!(root, "node-b", 10)

    become!(root, "node-a")
    a_claims = claim_concurrently(token, "a", 10)
    assert length(a_claims) == 10
    assert row("node-a").active == 10
    assert row("node-b").active == 0

    # node-a is full and says so, while node-b has not lost a single slot to it.
    {:ok, overflow} = Jobs.Admission.admit(token, request("a-overflow"))
    assert {:error, :capacity_exhausted} = Jobs.claim(overflow, "a-overflow-runner")

    become!(root, "node-b")
    b_claims = claim_concurrently(token, "b", 10)
    assert length(b_claims) == 10
    assert row("node-a").active == 10
    assert row("node-b").active == 10

    assert Repo.aggregate(
             from(a in JobAttempt, where: a.status in ["provisioning", "running"]),
             :count,
             :id
           ) == 20

    assert Enum.map(a_claims, & &1.machine_id) |> Enum.uniq() == ["node-a"]
    assert Enum.map(b_claims, & &1.machine_id) |> Enum.uniq() == ["node-b"]
    assert Jobs.cluster_capacity() == %{capacity: 20, active: 20}
  end

  test "sync_capacity prunes a migrated phantom row so cluster capacity matches this host",
       %{root: root} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ExecutionCapacity{
      node_id: "local",
      capacity: 8,
      active: 0,
      inserted_at: now,
      updated_at: now
    })

    boot!(root, "solo-host", 16)

    assert Repo.get(ExecutionCapacity, "local") == nil
    assert Jobs.cluster_capacity() == %{capacity: 16, active: 0}
    assert row("solo-host").capacity == 16
  end

  test "sync_capacity keeps a declared peer row while pruning undeclared phantoms", %{root: root} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ExecutionCapacity{
      node_id: "local",
      capacity: 8,
      active: 0,
      inserted_at: now,
      updated_at: now
    })

    Repo.insert!(%ExecutionCapacity{
      node_id: "node-b",
      capacity: 10,
      active: 0,
      inserted_at: now,
      updated_at: now
    })

    boot!(root, "node-a", 10)

    assert Repo.get(ExecutionCapacity, "local") == nil
    assert row("node-b").capacity == 10
    assert Jobs.cluster_capacity() == %{capacity: 20, active: 0}
  end

  test "sync_capacity retains a phantom row while it still holds active reservations", %{root: root} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ExecutionCapacity{
      node_id: "local",
      capacity: 8,
      active: 3,
      inserted_at: now,
      updated_at: now
    })

    boot!(root, "solo-host", 16)

    assert row("local").active == 3
    assert Jobs.cluster_capacity() == %{capacity: 24, active: 3}
  end


  # DONE WHEN, parts two and three. This is the assertion the whole node-identity
  # phase was ordered for: `recover_stale/1` runs on *every* node, so the machine
  # that fails an expired attempt is routinely not the machine that reserved for
  # it. Releasing against `current_machine/0` would strand a slot on the dead node
  # forever and drive the survivor's counter below what it actually holds.
  test "a sweeping node releases the reserving node's slots and never its own", %{
    root: root,
    token: token
  } do
    boot!(root, "node-a", 10)
    boot!(root, "node-b", 10)

    become!(root, "node-a")
    dead = claim_concurrently(token, "dead", 4, lease_ms: 1)
    assert row("node-a").active == 4

    become!(root, "node-b")
    live = claim_concurrently(token, "live", 3)
    assert row("node-b").active == 3

    # node-a is gone. node-b sweeps, on node-b's clock, against node-a's leases.
    at = sweep_time(dead)
    assert {:ok, 4} = Jobs.recover_stale(at)

    assert row("node-a").active == 0
    assert row("node-b").active == 3
    assert row("node-a").capacity == 10
    assert row("node-b").capacity == 10

    # Exactly once: a second sweep has nothing left to give back, and the
    # survivor's own live attempts are untouched by either pass.
    assert {:ok, 0} = Jobs.recover_stale(at)
    assert row("node-a").active == 0
    assert row("node-b").active == 3

    Enum.each(live, fn attempt ->
      assert {:ok, _} =
               Jobs.complete(attempt, attempt.lease_token, :cancelled, %{
                 error: error("test_cleanup")
               })
    end)

    assert row("node-b").active == 0
    assert row("node-a").active == 0
  end

  # The other half of "exactly once": a slot given back by hand must not be
  # given back again by the lease sweep that arrives afterwards.
  test "a manually released slot is not released again by lease expiry", %{
    root: root,
    token: token
  } do
    boot!(root, "node-a", 10)
    boot!(root, "node-b", 10)

    become!(root, "node-a")
    {:ok, job} = Jobs.Admission.admit(token, request("double-release"))

    # An operator cancels a job whose lease has already lapsed. The slot comes
    # back here, and the sweep that arrives later must find nothing to give back
    # a second time — a cancellation racing a lease expiry over one attempt is
    # the ordinary way here, not an exotic one.
    {:ok, attempt} = Jobs.claim(job, "double-release-runner", lease_ms: 1)
    holders = claim_concurrently(token, "holder", 9)
    assert length(holders) == 9
    assert row("node-a").active == 10

    assert {:ok, %Job{status: "cancelled"}} = Jobs.cancel(job)
    assert row("node-a").active == 9

    become!(root, "node-b")
    assert {:ok, 0} = Jobs.recover_stale(sweep_time([attempt]))

    assert row("node-a").active == 9
    assert row("node-b").active == 0

    # The counter is asserted above, but a counter is only a claim about the
    # future. Cash it: exactly one slot came back, so exactly one more claim
    # fits and the next one does not. A release that ran twice would leave the
    # row at 8 and quietly run an eleventh container on a ten-slot machine.
    become!(root, "node-a")
    assert [_] = claim_concurrently(token, "refill", 1)
    assert row("node-a").active == 10

    {:ok, eleventh} = Jobs.Admission.admit(token, request("eleventh"))
    assert {:error, :capacity_exhausted} = Jobs.claim(eleventh, "eleventh-runner")
  end

  # Attempts claimed before `job_attempts.machine_id` existed carry NULL. They were
  # counted in the singleton row the migration re-keyed to `'local'`, so that is
  # the only row that can honestly give the slot back.
  test "an attempt with no recorded node releases against the migrated row", %{
    root: root,
    token: token
  } do
    become!(root, "local")
    assert {:ok, _} = Jobs.sync_capacity()

    {:ok, job} = Jobs.Admission.admit(token, request("legacy-attempt"))
    {:ok, attempt} = Jobs.claim(job, "legacy-runner")
    assert row("local").active == 1

    # Erase the node the way an upgraded row has it erased.
    Repo.update_all(from(a in JobAttempt, where: a.id == ^attempt.id), set: [machine_id: nil])
    attempt = Repo.get!(JobAttempt, attempt.id)
    assert attempt.machine_id == nil

    assert {:ok, _} =
             Jobs.complete(attempt, attempt.lease_token, :failed, %{error: error("worker_exit")})

    assert row("local").active == 0
  end

  defp boot!(root, node, max_concurrent) do
    become!(root, node, max_concurrent)
    assert {:ok, _} = Jobs.sync_capacity()
    :ok
  end

  # Everything a process learns about which machine it is: the environment, then
  # a config load. Exactly the boot sequence, minus the operating system.
  defp become!(root, node, max_concurrent \\ 10) do
    System.put_env("OMASHIKI_NODE", node)

    # A node outside the declared list is a config-load failure by design, so
    # the implicit-node path is reached by declaring nothing at all.
    nodes = if Map.has_key?(@nodes, node), do: @nodes, else: %{}

    load_config!(root, nodes, %{"max_concurrent_containers" => max_concurrent})
    assert Config.current_machine().name == node
    :ok
  end

  defp claim_concurrently(token, key, count, opts \\ []) do
    jobs =
      Enum.map(1..count, fn n ->
        {:ok, job} = Jobs.Admission.admit(token, request("#{key}-#{n}"))
        job
      end)

    jobs
    |> Task.async_stream(
      fn job -> Jobs.claim(job, "#{key}-runner-#{job.id}", opts) end,
      max_concurrency: count,
      timeout: 10_000
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, attempt}} -> [attempt]
      {:ok, _} -> []
    end)
  end

  defp sweep_time(attempts) do
    attempts
    |> Enum.map(& &1.lease_expires_at)
    |> Enum.max(DateTime)
    |> DateTime.add(1, :millisecond)
  end

  defp row(node), do: Repo.get!(ExecutionCapacity, node)

  defp load_config!(root, nodes, limits) do
    Config.load_map!(
      %{
        "nodes" => nodes,
        "repositories" => %{"app" => %{"path" => "repo", "base_branch" => "main"}},
        "presets" => %{
          "opencode" => %{"plugin" => "opencode", "options" => %{}}
        },
        "environments" => %{
          "safe" => %{
            "isolation" => "docker",
          "image" => "omashiki/agent:latest",
          "sink" => "git",
          "packages" => [],
          "preset" => "opencode",
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

  defp error(code), do: %{"code" => code, "message" => code, "details" => %{}}
end
