# Documentation

Start with the concepts. Each page explains one part of the product in
simple English. Technical documentation lives under
[internal/](internal/README.md).

## Concepts

1. [Roles](concepts/roles.md): operator, developer, house, machine, job,
   and the client at the door.
2. [The house registry](concepts/house-registry.md): `omashiki.toml`, the
   graph of presets and environments, `include`, secrets, hot reload.
3. [Machines and enrollment](concepts/machines-and-enrollment.md): add a
   machine, enroll it into houses, capacity, presence, deployment shapes.
4. [The life of a job](concepts/job-lifecycle.md): from the tracker to the
   result, and the three result sinks.
5. [Model access](concepts/model-access.md): gateway or subscription, and
   where the key lives.
6. [Agent identities](concepts/identities.md): a GitHub App as the face of
   the agent, served by the house.
7. [The client at the door](concepts/client-at-the-door.md): how an event
   becomes a job and how the result returns.
8. [Guarantees](concepts/guarantees.md): what never happens, what lives
   where, the promises and where the code backs them.

## Contract

- [Jobs OpenAPI](api/jobs-openapi.json): the public HTTP surface. Kept in
  step with `server/lib/omashiki_web/router.ex`.

## How-to

- [Example configurations](../examples/README.md): registries, Compose
  stacks, the handler example, and the secret model.
- [Quick start](../README.md) and [contributing](../CONTRIBUTING.md).

## Internal

[internal/](internal/README.md) holds architecture, requirements, data
model, design records, and engineering measurements. When two pages
describe the same behavior, the concept page is the product truth and
`internal/architecture.md` is the system truth.
