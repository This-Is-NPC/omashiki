# Design decisions

This page consolidates the previous product, plugin, task-processor, and fleet design records.
Current behavior is described separately from deferred proposals.
Historical source text remains in Git history.

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

The earlier `CliJson` extraction reduced duplicated CLI mechanics.
The historical cost measurement did not justify a manifest change by itself.
The later declarative implementation also addressed admitted definitions and configuration validation.
See [validation results](validation-results.md#harness-cost-record) for the measured counts.

## Explicit result sinks

**Accepted.** `git`, `files`, and `none` select different preparation and publication paths.
They share admission, attempt execution, events, cleanup, and terminal-state rules.
Output validation remains a core responsibility.

The earlier generic-task proposal used `result = "data"` and a workspace JSON result file.
Those proposed names are not the current contract.
The current non-Git paths use the `files` and `none` sinks.
An arbitrary environment-specific JSON result schema is not a documented supported interface.

## Dependency graph

**Accepted.** Jobs use directed dependency edges with explicit failure policy.
The previous single `parent_job_id` model was removed by migration.
Admission validates the graph before execution.
This avoids a cycle that would otherwise remain blocked indefinitely.
Dependency output can supply downstream workspace input and Git base selection.

## House and worker separation

**Accepted.** The house owns PostgreSQL and product policy.
The worker owns local slots and the Docker boundary.
Workers receive offers over HTTP and return results to the offering house.
One worker can enroll into several houses.
The local slot limit applies to all those houses together.

This replaces the requirement that every execution process share the house database.
The embedded shared-database deployment remains an available deployment option.
The [distributed protocol](distributed-execution.md) is the implementation reference.

## Fleet implementation record

The original six-phase house and fleet record reported completion on 2026-09-06.
Its implemented outcomes are:

| Phase | Outcome |
| --- | --- |
| 1 | Root-only includes with confined paths, duplicate-name rejection, and stable combined digests. |
| 2 | Worker-side `~/` expansion for host credential origins. |
| 3 | House-declared GitHub App identities attached to presets. |
| 4 | House-side identity broker with temporary job authorization. |
| 5 | Reference handler for labelled GitHub issues and terminal notifications. |
| 6 | Several houses sharing workers with separated mirrors, state, and results. |

Fleet slot ownership and multi-manager isolation were dependencies of the final phase.
The record retained two important gaps: simulated GitHub evidence and OpenCode-only identity configuration.
These gaps remain visible in [user limitations](../what-does-not-work.md).

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
