# Design decisions

This page records accepted choices and deferred work.
Use [architecture](architecture.md) for current component behavior.

## One admission boundary

**Accepted.** The client supplies an instruction and selects registered names.
It does not select provider credentials, arbitrary runtimes, or execution machines.
The environment determines the result sink and execution policy.

This permits code and non-code work through the same API.
Tracker-specific event mapping stays in the client handler.
The house remains independent of Jira, GitHub, or other event sources.

## Admitted snapshots

**Accepted.** Each job captures its repository, environment, and resolved plugin with digests.
Workers execute those definitions rather than reloading their own registry.
This prevents configuration changes from changing already admitted work.
Private identity keys and provider API keys remain outside those snapshots.

## Declarative plugins

**Accepted.** TOML manifests describe supported transport and output behavior.
The interpreter handles common execution mechanics.
Presets supply options and identities.
Environments supply policy and runtime selection.

Templates use literal substitution into argument arrays and files.
They do not evaluate shell expressions.
Output decoding remains explicit because tool formats differ.
The `requires.binaries` check compares plugin needs with image and package contents.

## Explicit result sinks

**Accepted.** `git`, `files`, and `none` select different preparation and publication paths.
They share admission, attempt execution, events, cleanup, and terminal-state rules.
Output validation remains a core responsibility.
An environment-specific JSON result schema is not a supported interface.

## Dependency graph

**Accepted.** Jobs use directed dependency edges with explicit failure policy.
Admission validates the graph before execution.
This avoids a cycle that would otherwise remain blocked indefinitely.
Dependency output can supply downstream workspace input and Git base selection.

## House and worker separation

**Accepted.** The house owns PostgreSQL and product policy.
The worker owns local slots and the Docker boundary.
Workers receive offers over HTTP and return results to the offering house.
One worker can enroll into several houses.
The local slot limit applies to all those houses together.
A worker does not connect to the house database.
The embedded shared-database deployment remains an available option.
The [distributed protocol](distributed-execution.md) is the implementation reference.

## Fleet and configuration

**Accepted.** These configuration and fleet rules apply together.

| Area | Rule |
| --- | --- |
| Registry includes | Root-only includes, confined paths, duplicate-name rejection, and a stable combined digest. |
| Host credentials | The worker expands `~/` against its process home. |
| Identities | House-declared GitHub App identities attach to presets. |
| Identity broker | The house authorizes temporary job requests. |
| Reference handler | It admits labelled GitHub issues and verifies terminal notifications. |
| Shared workers | Several houses share workers. Mirrors, state, and results stay separated. |
| Slots | One local slot limit applies across enrolled houses. |

## Credential ownership

**Accepted.** Gateway provider keys stay in the house.
Subscription credential origins stay on the execution machine.
Each attempt receives a private copy.
OAuth refresh can update that copy but does not update the source file.

**Deferred.** Automatic OAuth write-back to the original credential file.
Such a change needs explicit ownership, concurrency, and recovery rules.
It must not overwrite another attempt's refreshed state.

## Kata selection

**Accepted with deployment prerequisites.** Kata is a Docker handler selected by the environment.
The host must install and register it.
Runtime selection does not bypass normal policy or finalization checks.

**Evidence limit.** The host smoke checks runtime selection and exec.
Full filesystem, credential, socket, network, and resource compatibility needs workload-specific evidence.
See [the Kata reference](runtime-kata.md).

## Deferred behavior

No current contract permits a client to select a GPU worker.
No public MCP endpoint substitutes for the job HTTP API.
No built-in tracker connector supplies Jira or ServiceNow integration.
No automatic Git merge or result-comment callback belongs to the reference handler.
Treat these as separate changes with their own requirements if proposed.
