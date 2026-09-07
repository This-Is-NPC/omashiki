# Documentation

Start with the product. Everything technical lives under
[internal/](internal/README.md).

## Product

- [Omashiki to-be](omashiki-to-be.md): the product, feature by feature — houses,
  machines, a job's day, paying for the model, agent identities, the client
  at the door, what never happens, and the guarantees with where the code
  backs each one.
- [Jobs OpenAPI](api/jobs-openapi.json): the public HTTP surface — admission,
  inspection, lifecycle control, events, and delivery status. Kept in step
  with `server/lib/omashiki_web/router.ex`.

## How-to

- [Example configurations](../examples/README.md): single-node and multi-node
  registries, manager and worker Compose, the handler at the door, and the
  secret model.
- [Quick start](../README.md) and [contributing](../CONTRIBUTING.md).

## Internal

[internal/](internal/README.md) holds architecture, requirements, data
model, design records and engineering measurements. When behaviour is
described in more than one place, the walkthrough is the product truth and
`internal/architecture.md` is the system truth.
