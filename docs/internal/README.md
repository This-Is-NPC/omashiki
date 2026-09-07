# Internal documentation

Technical documentation: how the system is built, what it guarantees, and
the design records behind it. The product itself is described in
[../walkthrough.md](../walkthrough.md).

## Reading Order

1. [Product requirements](prd.md): purpose, users, delivered features,
   guarantees, and scope.
2. [Architecture](architecture.md): runtime shape, trust boundaries,
   harnesses, and code references.
3. [Current requirements](requirements.md): implemented business,
   functional, and non-functional requirements.
4. [Data model](data-model.md): persisted entities, invariants, and
   lifecycle relationships.

## Design Records

Grounded in the current code; each carries its own status notes.

- [Casas e frota — registo de implementação](house-fleet-implementation.md):
  the six-phase work order that produced the house/fleet product, with a
  closing note per phase and the known gaps.
- [Manager and worker plan](distributed-execution.md): control plane owns
  PostgreSQL and the product registry; workers pull snapshots and never mount
  the database. 1:N, N:1 and N:M plus `git` / `files` / `none` sinks.
- [Kata Containers runtime handler](runtime-kata.md): Docker API and
  configuration support plus host deployment for per-sandbox kernels.
- [Generic task processor](generic-task-processor.md): structured non-Git
  results and optional repositories, without weakening the caller boundary.
- [Plugins and task lifecycle](plugins-e-ciclo-de-vida.md): declarative
  plugin manifests, harness cost model, and Wave 2 gate criteria.
- [Harness next-cost measurement](harness-next-cost.md): post-CliJson
  re-measurement and Wave 2 gate verdict.

## Engineering Records

- [Load test, wave 1](loadtest-wave1-400-durability.md): the 400-job
  durability run and what it proved about NFR-001.
- [CI baseline](ci-baseline.md): exit code and headline result of every
  local CI target at a named commit, plus the standing gaps.

## Component Documentation

- [Agent images](../../agent/README.md): building and maintaining the
  sandbox images.
- [Example configurations](../../examples/README.md): registries, Compose
  stacks, the handler example, and the secret model.
- [Load test harness](../../.scripts/loadtest/README.md): prerequisites,
  tier stanzas, and how to drive a run.
- [VM orchestration](../../vm/README.md): the disposable VMs used for
  distributed execution tests.

## Documentation Ownership

- `docs/walkthrough.md` owns product behaviour as the user meets it.
- `docs/internal/` owns architecture, contracts, security guarantees, and
  cross-component operational concepts.
- The root [`README.md`](../../README.md) owns project discovery and quick
  start; [`CONTRIBUTING.md`](../../CONTRIBUTING.md) owns contributor
  workflow, local secrets, tests, and hooks.
- Component READMEs own only component-specific build and runtime
  instructions and link back here for system behaviour.
