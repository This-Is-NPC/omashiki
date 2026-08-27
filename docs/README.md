# Documentation

This directory is the canonical source for Omashiki product and system
documentation.

## Reading Order

1. [Product requirements](prd.md): product purpose, users, delivered features,
   guarantees, and scope.
2. [Architecture](architecture.md): runtime shape, trust boundaries, harnesses,
   and code references.
3. [Current requirements](requirements.md): implemented business, functional,
   and non-functional requirements.
4. [Data model](data-model.md): persisted entities, invariants, and lifecycle
   relationships.

## Design Direction

These documents describe work that is designed but not implemented. They are
grounded in the current code and state what each change actually requires; they
are not a description of shipped behavior. Anything they contradict in the four
documents above is aspirational, not current.

- [Distributed execution](distributed-execution.md): running the queue across
  several nodes with PostgreSQL as the coordination authority.
- [Kata Containers runtime backend](runtime-kata.md): a second execution
  backend giving each sandbox its own kernel.
- [Generic task processor](generic-task-processor.md): structured non-Git
  results and optional repositories, without weakening the caller boundary.
- [Plugins and task lifecycle](plugins-e-ciclo-de-vida.md): declarative plugin
  manifests, harness cost model, and Wave 2 gate criteria.

## Engineering Records

- [CI baseline](ci-baseline.md): the recorded exit code and headline result of
  every local CI target at a named commit, plus the standing gaps that run
  exposed. Later changes claiming "CI is still green" compare against it.

## Documentation Ownership

- `docs/` owns product behavior, architecture, contracts, security guarantees,
  and cross-component operational concepts.
- The root [`README.md`](../README.md) owns project discovery and quick start.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) owns contributor workflow, local
  secrets, tests, and hooks.
- Component READMEs, such as [`agent/README.md`](../agent/README.md), own only
  component-specific build and runtime instructions.
- A README beside a generated or captured artifact may explain how to refresh
  that artifact, but must link back here for system behavior.

When behavior is described in more than one place, the document under `docs/`
is canonical. Local READMEs should summarize and link rather than duplicate
architecture or requirements.
