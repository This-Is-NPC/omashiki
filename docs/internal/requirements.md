# Requirements

These requirements describe the implemented product boundary.
Current evidence limits are listed in [validation results](validation-results.md) and [user limitations](../what-does-not-work.md).

## Product scope

A client submits an instruction and selects a registered environment.
The house retains the job and its configuration.
A machine executes each attempt in a controlled container.
The sink selects a Git branch, file archive, or completion metadata.

The supported roles are embedded, manager, and worker.
A worker can serve several houses with separate state and results.
Clients retain responsibility for tracker integration, review, and merge decisions.

## Business requirements

| ID | Requirement |
| --- | --- |
| BR-001 | Admit only declared environments and applicable registered repositories. Capture their resolved definitions. |
| BR-002 | Accept a neutral instruction payload. Refuse caller-supplied provider, model, harness, and authentication controls. |
| BR-003 | Return the existing job for the same submitting token and idempotency key. Refuse conflicting token ownership. |
| BR-004 | Admit batches atomically, with no more than 100 jobs. |
| BR-005 | Apply explicit dependency edges and their `cancel`, `block`, or `proceed` failure policy. |
| BR-006 | Limit active execution to the machine's declared capacity. Shared houses must share the worker's local limit. |
| BR-007 | Retry failed or cancelled jobs with the same ID and the next attempt number. Do not reopen success. |
| BR-008 | Validate output according to the configured sink before recording success. |
| BR-009 | Sign configured terminal notifications. Retry within 24 hours and support duplicate delivery. |
| BR-010 | Apply event, queue, and Git run-branch retention. Preserve applicable successful task pointers. The default horizon is 30 days. |

## Functional requirements

| ID | Requirement |
| --- | --- |
| FR-001 | Provide public health, first-operator signup, and credential-based token issuance. Authenticate job operations. |
| FR-002 | Return safe repository and environment discovery metadata. Omit secrets and host credential paths. |
| FR-003 | Accept one V1 envelope or a batch. Apply the neutral V2 payload contract to each job. |
| FR-004 | Return accessible job state, attempt identity, terminal results, and errors. |
| FR-005 | Record cancellation before runtime interruption. Permit retries only from failed or cancelled state. |
| FR-006 | Provide retained event history and SSE with `Last-Event-ID` replay. |
| FR-007 | Expose redacted terminal-delivery status. |
| FR-008 | Provide Home and configuration browser views. Provide lifecycle operations through the public API. |
| FR-009 | Execute preparation, agent invocation, conditional post-steps, finalization, and cleanup with bounded step records. |
| FR-010 | Use separate temporary claims for model, tool, package, and egress access. Bind claims to admitted job policy. |
| FR-011 | Record usage with a stable request ID. Preserve unknown provider counts as unknown. |
| FR-012 | Apply configured package registry policy. Audit records violations; allowlist mode refuses unauthorized requests. |
| FR-013 | Enroll workers into multiple houses and retain enrollments across restart. |
| FR-014 | Execute admitted plugin definitions rather than mutable live manifests. |
| FR-015 | Support Git, files, and none sinks. Permit omitted repositories for non-Git work. |
| FR-016 | Serve configured GitHub App identity tools through the house broker for supported plugins. |

## Non-functional requirements

| ID | Requirement |
| --- | --- |
| NFR-001 | Persist admission, attempt creation, initial events, and dispatch transactionally. |
| NFR-002 | Fence active attempts with expiring leases. Recover stale attempts and release capacity once. |
| NFR-003 | Drop container capabilities, disable privilege escalation, and enforce filesystem and resource policy. |
| NFR-004 | Reject path escapes and unsafe symlink components in repositories, caches, mounts, and results. |
| NFR-005 | Reject protected paths, likely secrets, symlinks, and oversized Git changes before publication. |
| NFR-006 | Apply upstream validation to restricted gateways and proxies. Do not extend this claim to explicit host networking. |
| NFR-007 | Keep gateway API keys in the house. Restrict and clean temporary credential copies. |
| NFR-008 | Preserve event ordering and bounded replay. Fail on missing retained sequences. |
| NFR-009 | Sign canonical terminal payloads with timestamp-bound HMAC-SHA256 and support key rotation. |
| NFR-010 | Enforce ownership on job, dependency, usage, and delivery access. Validate admitted digests on runtime claims. |
| NFR-011 | Exclude credentials and full prompt or file contents from ordinary logs and durable observation data. |
| NFR-012 | Isolate attempt failures through supervision and recovery. Avoid serializing unrelated runtime operations. |
| NFR-013 | Keep result delivery and worker state separated by house. |

## Executable references

- [Envelope and payload contracts](../../server/lib/omashiki/jobs/contract)
- [Admission](../../server/lib/omashiki/jobs/admission.ex)
- [State transitions](../../server/lib/omashiki/jobs.ex)
- [Database migrations](../../server/priv/repo/migrations)
- [Runtime runner](../../server/lib/omashiki/jobs/runner.ex)
- [Worker slots](../../server/lib/omashiki/worker/slots.ex)
- [Network checks](../../server/lib/omashiki/security/network.ex)
