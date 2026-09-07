# Product Requirements: Queue Runner

## Vision

Omashiki turns a harness-neutral instruction and optional structured context
into a durable, observable execution job. A client chooses a registered
repository and environment and receives a governed attempt that either produces
a clean committed Git result or a durable, actionable failure. The product is
intentionally a queue runner: clients retain ownership of the work they want
done and use Omashiki for reliable admission, execution, observation, and
delivery.

## Users and Value

- **Job client:** submits work without exposing provider credentials or runtime
  internals, and can safely retry a request using an idempotency key.
- **Operator:** sees capacity, waiting work, active attempts, terminal results,
  event history, and delivery failures from a local operations surface.
- **Result consumer:** receives a signed terminal notification and can fetch the
  same result and event history through the authenticated API.

The value is predictable execution rather than another planning surface: durable
queue state, dependency ordering, isolated attempts, clean Git artifacts, and
replayable evidence of what happened.

## Delivered Features

- Accept one job or an atomic batch with a required instruction, optional JSON
  context, priority, idempotency, correlation, and optional parent ordering.
- Resolve only registered repositories and environments and preserve the chosen
  definitions for the lifetime of the job.
- Queue work durably, limit active execution, unlock children after the first
  successful parent, and keep children waiting when the parent does not succeed.
- Execute each attempt in a governed disposable environment with declared
  preparation and completion steps through a registered OpenCode or Claude Code
  harness profile.
- Return a clean committed branch with its base and result revisions when an
  attempt succeeds; return a structured terminal error otherwise.
- Cancel waiting or active work and retry failed or cancelled work as the same
  job with a new numbered attempt.
- Inspect job state and results through an authenticated API and local operator
  views.
- Replay retained event history or follow a live SSE stream without gaps using
  `Last-Event-ID`.
- Deliver signed terminal notifications with durable retry and dead-letter
  visibility.
- Keep provider credentials outside the execution environment and mediate LLM,
  tool, package, and restricted network access through job-scoped boundaries.

## Product Guarantees

- A submitted job is not silently duplicated when the same owner and
  idempotency key are received again.
- A successful result is a clean, reachable branch with verifiable base and head
  revisions.
- A numbered attempt has one terminal outcome, and a successful job cannot be
  reopened.
- Terminal delivery is at-least-once. Consumers deduplicate notifications by
  event identifier.
- Retained event history and Oban queue rows use the configured 30-day horizon;
  successful result branches have a 30-day pruning policy.

## Current Scope

The product serves local, governed execution against configured repositories and
environments. It supports up to eight active containers and batches of up to 100
jobs. Cloud worker fleets and unregistered execution targets are outside the
current product boundary.

See [architecture](architecture.md), [data model](data-model.md), and
[requirements](requirements.md) for the verified current state.
