# Distributed Execution Roadmap

Design direction for running one central queue whose work executes either on the
same host or spread across several. Same release, different roles. PostgreSQL
stays the coordination authority: no distributed Erlang, no libcluster.

Status: **not implemented.** Phases are ordered by dependency, and each one
names the condition that closes it.

## Current State

What already works across nodes, unchanged:

- **Pull-based dispatch.** `Omashiki.Jobs.DispatchWorker` claims through
  `Jobs.claim/3`, which reserves capacity and returns `{:snooze, 1}` when there
  is no slot (`dispatch_worker.ex:38`). Oban lives in PostgreSQL, so N nodes
  running the `scheduler` queue contend for jobs correctly.
- **Fencing leases.** `lease_token` plus `lease_expires_at` and
  `Omashiki.Jobs.Recovery` already handle a dead node: the lease expires and
  capacity is released exactly once (NFR-002).
- **Port allocation.** The allocator is per-VM, which is the correct multi-node
  behaviour — each node leases its own local ports. Do not promote it to a
  global resource.

What breaks on the second node: global capacity, the result stranded on local
disk, and the Docker socket pinned at compile time.

### Two defects to fix before distributing

**Dispatch durability is broken today.** The claim path contends correctly, but
the enclosing Oban job does not survive a failure. `DispatchWorker` declares
`max_attempts: 1` (`dispatch_worker.ex:6`), so any `{:error, reason}` return
(`:35`, `:45`) discards the Oban job on its first failure while the `jobs` row
stays `queued` with no `terminal_error`. Recovery does not reconcile it either:
`recover_stale_locked/1` (`jobs.ex:497`) only scans attempts whose status is in
the active set, and a job that was never claimed has no active attempt. The
400-job load test produced 109 rows in exactly that state. This violates NFR-001
and falls through the gap in NFR-002. N nodes multiply the loss rather than
absorbing it, so this is a prerequisite, not a parallel concern.

**`recover_stale_locked/1` runs inside every `claim`.** `Jobs.claim/3` calls it
at the top of the claim transaction (`jobs.ex:41`), before it even looks at its
own job. Every claim therefore opens a transaction that scans all expired active
attempts and takes a row lock per candidate. That is a cluster-wide
serialization point with the same convoy shape as the `api_tokens` row lock
found during load testing, and it gets worse in proportion to node count. Hoist
stale recovery out of `claim` and leave it to `Omashiki.Jobs.Recovery` before
Phase 3 makes claims more frequent.

## Phase 1 — Result Off the Node

Do this first. It depends on no other phase and it is the only one that changes
observable product behavior.

**Problem.** Success is a local `omashiki/job-<id>` branch inside `<repo_path>`
on the machine that executed (`jobs/git_artifact.ex:159-168`). If that node dies,
or the client asks a different node, the deliverable is gone.

**Change.** Finalization publishes to a canonical remote. The local branch
becomes an execution detail and the result becomes
`(remote, branch, base_sha, head_sha)`.

- [ ] A canonical remote field per repository in `omashiki.toml`
- [ ] `GitArtifact.finalize` pushes after the safety validations — secret,
      symlink, protected path, and the 100 MiB cap stay **before** the push
      (NFR-005)
- [ ] The API result exposes the remote
- [ ] `prune_expired/2` prunes on the remote, not only locally

**Done when:** a job's branch is reachable from a machine that did not run the
attempt.

## Phase 2 — Node Identity

Cheap now, expensive to retrofit: recovery needs to know whose lease it was.

- [ ] A stable `node_id` per process, from an environment variable with a
      hostname fallback
- [ ] Persist it on `job_attempts`. `runner_id` already exists and currently
      receives `"oban:<id>"`; either extend that value or add a column
- [ ] Surface the node on the job detail view in the operator UI

**Done when:** "which machine ran this attempt?" is answerable from the
database.

## Phase 3 — Capacity Per Node

The central change. `execution_capacity` is a single row guarded by
`CHECK (id = 1)`
(`priv/repo/migrations/20260101000000_initial_schema.exs:183`), and
`Jobs.sync_capacity/0` writes `[limits].max_concurrent_containers` into it at
boot — so the second node to start overwrites the first node's capacity.

- [ ] Migration: drop `CHECK (id = 1)`, key the table by `node_id`, one row per
      node
- [ ] `reserve_capacity!/0` (`jobs.ex:553`) reserves against the **own** node's
      row. The `UPDATE ... WHERE active < capacity` pattern does not change, so
      the whole existing correctness argument carries over
- [ ] `release_capacity!/0` releases against the row that reserved, which is why
      Phase 2 comes first
- [ ] `sync_capacity/0` reconciles only its own row at boot
- [ ] `Recovery` releases against the right row when a lease expires
- [ ] Aggregate cluster capacity in the operator UI, as the sum of the rows

**Done when:** two nodes with `max_concurrent_containers = 10` each run 20
simultaneous attempts, and killing one does not affect the other's capacity.

## Phase 4 — Per-Node Configuration and Roles

- [ ] `docker_socket_path` leaves `Application.compile_env`
      (`runtime/container_manager.ex:31`) and becomes runtime configuration
- [ ] Process role by configuration: `central` (HTTP, LiveView, Oban) and
      `worker` (the `scheduler` queue plus Docker, no HTTP). Same release
- [ ] Worker boot validates Docker, mounts, and declared repositories, and fails
      loudly if the node cannot serve the environments it registered
- [ ] Decide repository locality: a per-node mirror with a `fetch` before the
      worktree. This is simple after Phase 1, because there is already something
      to mirror from
- [ ] Verify that environment and registry digests match across nodes.
      Divergent configuration between machines must be an error, not a runtime
      surprise

**Done when:** a new worker joins the cluster by pointing at PostgreSQL alone
and starts pulling work.

## Phase 5 — Multi-Model Fan-Out and Judge/Merge

This blocks nothing above. It is recorded so that Phase 4 does not close doors
here.

**Fan-out is already expressible.** An environment already fixes harness plus
credential plus model, so "the same task across 4 models" is 4 jobs with the
same `instruction` and 4 environments, submitted as one atomic batch. No new
code. The caller still does not choose a model — the operator declares the pool.

**What is missing is the fan-in:**

- [ ] N:1 dependency. `unlock_children!` (`jobs.ex:470`) is 1:N through
      `parent_job_id`. This needs a join table and a join policy
      (`all_terminal` / `quorum` / `first_success`). Note that BR-005 currently
      says a failed parent does not unlock; for a judge, a failed candidate is
      information
- [ ] A **system-injected** context channel, separate from the caller's
      `context` (`contract/payload_v2.ex`), to hand the candidate refs over at
      unlock. Keeping it separate is what preserves "the caller does not control
      the harness" (BR-002)
- [ ] A verification `post_step` with a structured result: does it compile, do
      the tests pass, is the diff minimal. Rank candidates by objective signal;
      a model judge only breaks ties among those that passed
- [ ] A cost policy per task class. N models is N times the cost, never a global
      mode

Judge and merge are the same primitive: a job whose instruction is to evaluate
or to merge, given N branches. A merge is a judge that emits code instead of
picking.

The structured-verification item has the most leverage on that list — it serves
best-of-N selection, fleet maintenance ("did the migration pass?"), and an
evaluation harness. It is worth pulling out of this phase and doing earlier.

## Do Not Do

- **libcluster, Horde, or distributed Erlang.** PostgreSQL is already the
  coordination layer, with fencing leases and recovery. BEAM clustering adds a
  distributed registry that is not needed and a split-brain that does not exist
  today. If cross-node PubSub becomes necessary, use the PostgreSQL adapter.
- **Untrusted nodes.** The whole NFR set assumes the operator owns the node:
  credentials on the host, a trusted gateway, finalization on a machine they
  control. Third-party nodes require attestation or verifiable execution, which
  is a different product.
- **A shared filesystem for repositories.** Git over NFS has unreliable
  locking. Mirror per node.

## References

- [Job lifecycle](../server/lib/omashiki/jobs.ex)
- [Durable dispatch](../server/lib/omashiki/jobs/dispatch_worker.ex)
- [Stale-attempt recovery](../server/lib/omashiki/jobs/recovery.ex)
- [Git artifact boundary](../server/lib/omashiki/jobs/git_artifact.ex)
- [Container boundary](../server/lib/omashiki/runtime/container_manager.ex)
- [V2 neutral payload](../server/lib/omashiki/jobs/contract/payload_v2.ex)
- [Database schema](../server/priv/repo/migrations/20260101000000_initial_schema.exs)
- [Requirements](requirements.md)
- [Architecture](architecture.md)
