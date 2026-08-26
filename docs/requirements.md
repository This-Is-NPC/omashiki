# Current Requirements

These requirements describe the implemented queue runner. They are organized
as business, functional, and non-functional requirements and use the current
contract vocabulary.

## Business Requirements

- **BR-001 Admission boundary:** Only registered repositories and environments
  may receive work. Their resolved definitions are captured with the job.
- **BR-002 Payload boundary:** The public payload uses neutral V2: a required
  non-blank `instruction` string and an optional JSON-object `context`. It is at
  most 1 MiB after JSON encoding and rejects harness control fields.
- **BR-003 Idempotent submission:** Repeating an owner/key pair returns the
  existing job; using that key through another token is a conflict.
- **BR-004 Atomic batches:** A batch contains at most 100 jobs, admits all jobs
  or none, and parent references point to another item in the same batch.
- **BR-005 Ordered execution:** A child remains blocked until its direct parent
  succeeds for the first time. A failed or cancelled parent does not unlock it.
- **BR-006 Capacity:** No more attempts may reserve local execution capacity at
  once than `[limits].max_concurrent_containers` declares.
- **BR-007 Attempt identity:** Retry reopens the same job with the next positive
  attempt number. Success is irreversible; failed and cancelled jobs are
  retryable.
- **BR-008 Result integrity:** Success requires a clean committed branch with
  base and head Git revisions. Unsafe or oversized output cannot be delivered.
- **BR-009 Terminal delivery:** Configured terminal notifications are signed,
  retried for 24 hours, and then marked dead. Delivery is at-least-once.
- **BR-010 Retention:** Event replay and Oban queue rows use the configured
  30-day horizon; successful result branches use a 30-day pruning policy.

## Functional Requirements

- **FR-001 Authentication:** `GET /api/v1/health` is public. Signup and token
  issuance are available at `/api/v1/sessions/signup` and
  `/api/v1/sessions/issue_token`; queue operations require Bearer auth.
- **FR-002 Discovery:** Authenticated clients can list safe repository metadata
  at `GET /api/v1/repositories` and environment metadata at
  `GET /api/v1/environments`.
- **FR-003 Admission:** `POST /api/v1/jobs` accepts one V1 job envelope whose
  `payload` follows neutral payload V2; `POST /api/v1/jobs/batch` accepts an
  atomic batch of the same job shape. Responses identify each admitted job,
  its status, attempt, parent, and timestamps.
- **FR-004 Inspection:** `GET /api/v1/jobs`, `GET /api/v1/jobs/:id`, and
  `GET /api/v1/jobs/:id/result` expose owner-scoped state and terminal results.
  A result is unavailable until the job is terminal.
- **FR-005 Lifecycle control:** `POST /api/v1/jobs/:id/cancel` durably cancels
  waiting or active work and then interrupts any registered active runtime.
  `POST /api/v1/jobs/:id/retry` queues a new attempt only for a failed or
  cancelled job.
- **FR-006 Event history:** `GET /api/v1/jobs/:id/events/history` returns
  retained contiguous events. `GET /api/v1/jobs/:id/events` and `/events/stream`
  stream the same event sequence as SSE and accept `Last-Event-ID`.
- **FR-007 Delivery status:** `GET /api/v1/jobs/:id/webhook-deliveries` returns
  owner-scoped redacted delivery state without payload secrets.
- **FR-008 Operator surface:** The local UI provides overview, queue, job
  detail, and configuration views. It shows waiting/active work, capacity,
  terminal events, attempts, steps, usage, Git result metadata, and delivery
  failures; job detail permits cancellation and retry where valid.
- **FR-009 Execution lifecycle:** An attempt performs configured preparation
  steps, one harness turn using the job payload, conditional completion steps,
  result finalization, and cleanup. Each step records status and bounded output
  or error data.
- **FR-010 Runtime authorization:** Active attempts receive short-lived claims
  separately scoped for the LLM gateway, tool proxy, package proxy, and egress.
  Claims bind owner, job, environment digest, and any credential or policy.
- **FR-011 Usage accounting:** Gateway and engine usage is recorded with a
  stable request ID; provider-reported unknown token categories remain unknown.
- **FR-012 Package policy:** When a cache policy is configured, npm, Cargo, and
  Go requests use declared registries. Audit mode records violations; allowlist
  mode blocks unauthorized packages, versions, and sources.

## Non-Functional Requirements

- **NFR-001 Data durability:** Admission, the first state event, the first
  attempt, and dispatch are transactionally persisted. State transitions and
  terminal event/outbox creation are durable and idempotent.
- **NFR-002 Crash recovery:** Claims use expiring fencing leases and serialized
  capacity reservations. Recovery marks stale active attempts failed exactly once
  and releases their reservation.
- **NFR-003 Isolation:** Execution containers drop all Linux capabilities,
  disable privilege escalation, use a read-only root filesystem and bounded
  tmpfs, run with the repository owner IDs, and enforce CPU, memory, and PID
  limits.
- **NFR-004 Filesystem safety:** The parent repository is read-only except for
  the governed Git metadata and job worktree. Repository, cache, mount, and
  result paths reject escapes and symlink components.
- **NFR-005 Result safety:** Finalization rejects likely secrets, protected
  paths, symlinks, and changes above 100 MiB before committing output.
- **NFR-006 Network safety:** LLM egress accepts only exact configured hosts on
  port 443 with public DNS results. Package and tool upstreams reject embedded
  credentials, fragments, invalid schemes, redirects, private/reserved
  addresses, and responses above their configured limits.
- **NFR-007 Credential handling:** Provider keys remain on the host. Runtime
  claims are short-lived; temporary secret files are restrictive, read-only in
  the container, and removed after harness readiness. Rotating OAuth credentials
  may persist through one explicit writable file below `/run/omashiki/state`;
  provider home/config directories are never mounted.
- **NFR-008 Observation continuity:** SSE pages are bounded, ordered by sequence,
  replayable through `Last-Event-ID`, and fail closed rather than fabricating a
  missing event after a retention gap.
- **NFR-009 Delivery security:** Terminal payloads use canonical JSON and
  timestamp-bound HMAC-SHA256. Receivers can deduplicate by event ID and verify
  the current or previous rotated key.
- **NFR-010 Authorization:** A token can read and submit only its owner's jobs;
  runtime claims additionally verify the captured environment and policy
  digests. Job and delivery reads do not disclose another owner's data.
- **NFR-011 Secret-safe observability:** Logs and durable event data exclude
  credentials, bearer values, complete prompts, complete responses, and file
  contents. Usage rows are append-only and keyed for retry idempotency.
- **NFR-012 Resilience:** Docker, Git, harness, proxy, queue, and delivery
  boundaries are supervised or recoverable so one failed attempt does not bring
  down unrelated work. Active attempts have independent temporary OTP processes;
  blocking runtime operations do not serialize unrelated attempts.

## References

- [V1 job envelope](../server/lib/omashiki/jobs/contract/v1.ex)
- [V2 neutral payload](../server/lib/omashiki/jobs/contract/payload_v2.ex)
- [Admission and lifecycle](../server/lib/omashiki/jobs/admission.ex)
- [Job state machine](../server/lib/omashiki/jobs.ex)
- [Runner safeguards](../server/lib/omashiki/jobs/runner.ex)
- [Network safeguards](../server/lib/omashiki/security/network.ex)
- [API routes](../server/lib/omashiki_web/router.ex)
- [Configuration](../omashiki.toml)
- [Release validation tests](../server/test/integration/queue_load_test.exs)
