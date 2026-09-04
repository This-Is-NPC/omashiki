# Manager and Worker Plan

Design direction for splitting Omashiki into a **manager** (control plane) and
**workers** (execution). Same release, different roles. The database and the
product registry belong to the manager. A worker never mounts PostgreSQL.

Status: **design.** Phases are ordered by dependency; each one names the
condition that closes it. This document replaces the earlier "N processes, one
Postgres" roadmap. Phases 1–3 of that revision (canonical Git remote, machine
identity, per-machine capacity rows) already shipped and remain foundations on
the **manager** side.

The three topologies are the same protocol, not three products:

| Shape | Meaning |
| --- | --- |
| **1 manager, N workers** | One control plane, a fleet of executors |
| **N managers, 1 worker** | Several products / tenants share one machine |
| **N:M** | Cartesian product of the two |
| **Embedded** | Manager with an in-process worker — today's single-node default |

Two manager *processes* in front of **one** Postgres are HA of HTTP, not N
managers. N managers means N databases and N registries.

Kata, Arch images, and judge/fan-in are out of this plan. Non-code work is
**in**: the environment already selects `sink = git | files | none`.

## Target Shape

```
Clientes A ──► Manager A + Postgres A ──┐
                                        ├── Worker × M
Clientes B ──► Manager B + Postgres B ──┘
                      ▲
                      └─── gateway / tools / packages stay on the owning manager
```

- Clients talk only to a manager.
- A worker **pulls** work. It does not accept inbound HTTP from the internet
  and does not share a database with anyone.
- Each admitted job already carries `admitted_environment`,
  `admitted_repository`, `admitted_plugin`, and `registry_digest`
  (`jobs/admission.ex`). The worker executes that snapshot. It never resolves
  an environment by name.
- `Complete` is a sum type keyed by sink, not "a Git branch".

## Ownership

| Concern | Manager | Worker |
| --- | --- | --- |
| Postgres, Oban, admission, UI, webhooks, SSE | yes | **no** |
| Product registry / `omashiki.toml` environments, presets, models | yes | **no** |
| Claim, lease row, recovery, digest | yes | heartbeat / result over the protocol |
| Docker, `docker_socket_path`, this machine's `[limits]` | no | yes |
| Git mirror + push of **that job's** snapshot remote | no | yes, `sink=git` only |
| `files` blob / `none` metadata | persist + serve | produce and return on `Complete` |
| LLM keys, MCP headers (NFR-007) | yes | short-lived claim, never the secret |
| Container slots | in-flight **of this manager** | **authority**: local semaphore |

Three rules make N:1 and N:M possible:

1. **The slot belongs to the worker.** Eight containers are the machine's, not
   eight per manager. Two managers must not reserve 8+8 and explode the host.
2. **The job knows its owner.** Result, events, and failure return only to the
   manager that admitted the work. A does not read B's jobs.
3. **The worker does not mix frontiers.** Worktree, tmpdir, network, and
   claims of a job from A never cross into a job from B.

## What Already Ships

Keep these; do not re-implement them behind the new transport.

- **Admission snapshots.** `Runner` reads `job.admitted_environment`, not the
  live registry (`jobs/runner.ex`). Gateway routing uses
  `Credentials.admitted/2`. A reload cannot move a job already in flight.
- **Sinks.** Registry requires `sink` in `git | files | none`
  (`config/registry.ex`). Admission omits `repo` for `files`/`none`.
  `GitArtifact` vs `WorkArtifact` already branches provision/publish.
  `VALIDATE` is sink-independent (`jobs/validate.ex`).
- **Canonical Git remote.** Finalization pushes `(remote, branch, base_sha,
  head_sha)` so a result is not stranded on the executing disk.
- **Machine identity.** `OMASHIKI_NODE` / `[nodes.*]`; attempts record
  `machine_id`.
- **Dispatch durability.** `DispatchWorker` retries (`max_attempts: 5`) and
  settles a stranded `jobs` row before Oban records the error. Stale recovery
  lives in `Jobs.Recovery`, not inside `claim/3`. The defects recorded in the
  previous revision of this file are closed in code; do not re-open them.
- **Fencing leases.** `LeaseRenewer` (5s tick, 60s window) plus
  `Jobs.Recovery`. Health of an attempt is the lease, not a node ping.
- **Tools over MCP.** Container talks to `Tools.Proxy` on the host; headers
  stay on the host. That host, after this plan, is the **manager that owns
  the job**.
- **Hot reload.** `Config.Rollout` (`gradual` / `drain_all`) applies to the
  process that holds the product TOML — the manager.

## What Breaks Against This Target

- Every process starts `Repo`, Endpoint, Oban, and Docker
  (`application.ex`). A "worker" today is a second copy of the app.
- `Jobs.claim/3` reserves `execution_capacity` in Postgres. That cannot be
  the machine's real slot once two managers share one worker.
- `docker_socket_path` is `Application.compile_env`
  (`runtime/container_manager.ex`).
- `WorkArtifact` writes `blob_path` on local disk. A remote worker would
  leave the product on the wrong machine.
- `DispatchWorker` claims and then runs `AttemptSupervisor` in the same
  BEAM. There is no transport seam.
- The checked-in multi-node example still describes "copy this TOML, point
  everyone at one Postgres". That is the transitional layout, not the target.

## Protocol

Pull. The worker is often behind NAT and must not expose HTTP. N managers
are N `(url, worker_token)` pairs in the worker's machine config.

```
Register  →  Poll(free_slots, machine)  →  Offer
                 ↓
              Accept  (local semaphore, atomic)
                 ↓
              Run snapshot  ── Heartbeat / events / Cancel-on-next-tick
                 ↓
              Complete {sink, git | files | none | error}
```

| Message | Direction | Contract |
| --- | --- | --- |
| `Register` | worker → manager | machine id, runtime handlers, images present, max slots |
| `Poll` | worker → manager | `free_slots`. Manager offers at most that many jobs from **its** queue |
| `Accept` | worker → manager | worker has taken a local slot. If the slot vanished, reject and the manager re-queues |
| `Heartbeat` | worker → manager | renews `lease_expires_at` on that manager's attempt row (~5s). Cancel is piggy-backed on the reply |
| `Complete` | worker → manager | sum type below. Manager writes the job row, webhook outbox, and its own in-flight count |

Auth: each manager issues a **worker token**, distinct from client API
tokens. The worker presents the matching token per URL. Managers never
share tokens or databases.

Cancel window is the heartbeat interval (same order as today's 5s/60s
lease). No push channel required for v1.

Single-node uses the same structs over `LocalWorker` (in-process). Zero
network hop; today's tests stay on that path.

### `Complete` by sink

The container, lease, and heartbeat do not change. Only the artefact does.
The environment selects the sink (BR-002: no `type` on the payload).

| Sink | Workspace | Success payload | Worker must not |
| --- | --- | --- | --- |
| `git` | worktree from the snapshot remote | `(remote, branch, base_sha, head_sha)` after push | invent another remote |
| `files` | tmpdir | validated blob (tar+digest today) **delivered to the manager** | leave `blob_path` only on worker disk |
| `none` | tmpdir | terminal metadata (`changed_bytes`, …) | clone or push |

`GET /api/v1/jobs/:id/result` and the signed webhook stay on the manager
(FR-004, BR-009). The worker does not retain the product.

Size: `WorkArtifact` caps at 100 MiB today. Inline vs signed-blob (256 KB
in `generic-task-processor.md`) is a later refinement of `files`; the
transport must already carry a blob or a manager-side upload. JSON Schema
validation of `/workspace/.omashiki/result.json` is **not** this plan —
it is items 1–2 of that document, after the hop knows `files`/`none`.

### Data plane

The sandbox on the worker calls the **owning manager's** LLM gateway, tool
proxy, and package proxy. Claims already bind
`admitted_environment_digest`. Keys never leave the manager (NFR-007).
This is the largest networking change versus today's localhost sockets.

If the worker cannot reach that manager's data plane, it **refuses** the
job rather than falling back to another manager's gateway.

### Isolation when N managers share a worker

- `git`: worktree and mirror keyed `manager-id/job-id`; push only that
  job's remote.
- `files` / `none`: tmpdir per attempt (`…/<manager-id>/<job-id>`),
  removed on destroy.
- Slots do not care about sink. A `none` job occupies a container the
  same way a `git` job does.

Fairness: round-robin poll across manager URLs so one manager cannot fill
the machine.

## Implementation Phases

### Phase 0 — In-process transport seam

Extract `Omashiki.Worker.Transport` with `offer / accept / heartbeat /
complete`. `DispatchWorker` stops calling `AttemptSupervisor` directly;
it offers through the transport. Default implementation: `LocalWorker`,
behaviour identical to today, including all three sinks.

`Complete` is the sum type from day one. Do not ship a Git-only callback
and retrofit `files` later — `blob_path` on the local disk is exactly the
bug Phase 1 would freeze.

**Touch:** `jobs/dispatch_worker.ex`, new `worker/transport.ex`,
`worker/local.ex`, `jobs/work_artifact.ex` (result already a map; keep it
serialisable), tests around `DispatchWorker` and the three sinks.

**Done when:** a local runc job of each sink (`git`, `files`, `none`)
succeeds with `LocalWorker` as the only path from dispatch to runner.
Existing `mise run e2e:overture` and mix tests stay green. No new HTTP,
no role flag, no topology change.

### Phase 1 — Remote worker, 1 manager : N workers

Same release, boot role `manager` | `worker`.

**Manager** keeps Repo, Endpoint, Oban (admission + webhooks), Rollout,
gateway, tools, packages. It does **not** start Docker, `LeaseRenewer`
for local attempts, or `ContainerManager` unless the embedded worker is
on. Internal HTTP (`/internal/work/*`) authenticates with the worker
token.

**Worker** starts Docker, `AttemptSupervisor`, `ContainerManager`,
`PortAllocator`, and a poll loop. It does **not** start `Repo`, Endpoint,
or Oban. Machine config only: `OMASHIKI_NODE`, `docker_socket_path`
(runtime, not `compile_env`), `max_concurrent_containers`, one
`(manager_url, token)`.

On `Accept`:

- `git` — fetch/mirror from the snapshot remote, worktree, finalize,
  push. No product TOML on the worker.
- `files` / `none` — tmpdir, validate, return artefact on `Complete`.
  No Git.
- Missing image, unreachable data-plane, or failed fetch → **refuse**,
  do not invent another environment.

UI lists workers that have polled recently and the slots they reported.
That is liveness of the *machine to this manager*, not a cluster
membership table.

**Done when:** a worker process on a second machine, given only URL +
token + Docker, runs a `git` job whose branch is reachable on the
canonical remote, and a `files`/`none` job whose result is served from
the **manager** API after the worker disk is wiped.

### Phase 2 — Worker owns the slot

Local semaphore is the authority. `execution_capacity` on the manager
becomes "attempts this manager currently has on workers", not "containers
on this box". `Accept` / reject is atomic on the worker. `Poll` carries
`free_slots`.

**Done when:** two managers (two Postgres, in test) cannot over-reserve a
worker with `max=2`. Killing the worker expires leases **independently**
on each manager (NFR-002 still holds per control plane).

This is the prerequisite for N:1. Do not skip it: Phase 1 can still cheat
by keeping a Postgres capacity row that looks like today's
`max_concurrent_containers`.

### Phase 3 — N:1 and N:M

Worker config is a list of managers. Round-robin poll, isolated
workspaces, `Complete` only to the owner, heartbeat/cancel on the right
manager. Embedded manager+worker remains the default for `mise run up`.

**Done when:** the same worker runs one job from A and one from B in
parallel without crossing Git remotes, blobs, events, or data-plane
claims; killing the worker recovers A on A and B on B.

## Operator Config After This Lands

**Manager** (product TOML, today's `omashiki.toml` minus host Docker
budget as cluster truth):

- repositories, presets, environments (including `sink`), runtimes
  catalog, credentials, caches, `[reload]`, `[auth]`, `[app]`, `[db]`
- worker tokens
- optional embedded worker for single-node

**Worker** (machine file, not the product registry):

- `OMASHIKI_NODE`
- `docker_socket_path`
- `max_concurrent_containers` and other host limits
- `managers = [{url, token}, …]`
- no environments, no models, no sinks — those arrive on the job

Secrets: LLM keys stay on the manager as `${env:VAR}`. Git push
credentials stay on the worker host (already forbidden inside the
container). A missing `${env:VAR}` still aborts boot.

## What This Replaces

The previous Phase 4 (identical TOML on every machine, cross-node
registry digest, worker that still speaks Postgres) is the wrong target
for this architecture. A worker has no registry, so digest comparison
across workers is meaningless. Divergence is a **manager** problem: two
managers with two TOMLs are two products. Two manager processes sharing
one Postgres must see one generation — one writer, or Postgres-backed
registry, not two files.

What is reused from that phase:

- `docker_socket_path` as runtime configuration → Phase 1
- boot roles → Phase 1
- per-node Git mirror → Phase 1, `sink=git` only, keyed by manager+job

Old Phase 5 (N:1 dependencies, judge/merge, verification `post_step`)
stays out. Fan-out is already an atomic batch of jobs against declared
environments. Fan-in does not change the worker protocol.

## Do Not Do

- **Worker mounts `Repo`.** That collapses N managers into one database
  and puts product policy on the executor.
- **Push dispatch to the worker.** NAT, extra attack surface, and a
  second HTTP stack on every executor.
- **libcluster / Horde / distributed Erlang.** Coordination is
  manager-local Postgres plus the pull protocol.
- **A `type` field on the payload.** Sink and toolchain are environment
  declarations (BR-002).
- **Shared filesystem for Git.** Mirror per worker; NFS locking is
  unreliable.
- **Untrusted workers.** NFR-004/007 assume the operator owns the
  machine. Third-party executors need attestation — a different product.
- **Manager-side container budget as the real slot after Phase 2.** It
  becomes in-flight accounting only.
- **Shipping Phase 1 Git-only.** `files`/`none` would keep writing
  local `blob_path` and break the moment a worker is remote.
- **JSON Schema `result.json` in this sequence.** Separate, after the
  transport carries `files`.

## Test Strategy

| Phase | Evidence |
| --- | --- |
| 0 | Mix tests: `LocalWorker` for `git`, `files`, `none`; existing dispatch durability tests still pass; `mise run e2e:overture` |
| 1 | One manager + one remote worker process (second BEAM or VM); `git` result on the canonical remote; `files` result on manager after worker tmp wipe; refuse path when the snapshot image is missing |
| 2 | Two manager apps, two test databases, one worker with `max=2`; over-accept is impossible; lease expiry is per manager |
| 3 | Same as 2 plus concurrent A+B jobs and independent recovery |

VM E2E (`mise run e2e:vm`) is the place for 1:N across hosts. N:1 can stay
in mix with two Repo configs until a second VM manager is worth the cost.

## Order of Work

0. Transport seam + serialisable `Complete` for every sink.
1. Roles, runtime Docker socket, internal poll API, remote 1:N, artefact
   delivery to the manager.
2. Worker semaphore as slot authority.
3. Multi-manager list, fairness, isolation.

Do not start 1 until 0 has `files`/`none` in the callback. Do not start 3
until 2 forbids over-reservation.

## References

- [Job lifecycle](../server/lib/omashiki/jobs.ex)
- [Durable dispatch](../server/lib/omashiki/jobs/dispatch_worker.ex)
- [Admission snapshots](../server/lib/omashiki/jobs/admission.ex)
- [Git artefact](../server/lib/omashiki/jobs/git_artifact.ex)
- [Non-Git artefact](../server/lib/omashiki/jobs/work_artifact.ex)
- [Sink-independent validate](../server/lib/omashiki/jobs/validate.ex)
- [Stale-attempt recovery](../server/lib/omashiki/jobs/recovery.ex)
- [Lease renewer](../server/lib/omashiki/runtime/lease_renewer.ex)
- [Container boundary](../server/lib/omashiki/runtime/container_manager.ex)
- [Config rollout](../server/lib/omashiki/config/rollout.ex)
- [V2 payload](../server/lib/omashiki/jobs/contract/payload_v2.ex)
- [Generic task processor](generic-task-processor.md)
- [Requirements](requirements.md)
- [Architecture](architecture.md)
