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
