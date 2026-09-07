# Internal documentation

Use these pages to develop, test, or change Omashiki.
For installation operation, use the [public documentation](../README.md).

## Start development

1. Read [contributing](contributing.md).
2. [Set up the development environment](how-to-set-up-development.md).
3. [Run the tests](how-to-run-tests.md).

## Development procedures

| Task | Page |
| --- | --- |
| Check manager and worker behavior | [Run distributed tests](how-to-run-distributed-tests.md) |
| Measure queue and container capacity | [Run load tests](how-to-run-load-tests.md) |
| Build or change sandbox images | [Build agent images](how-to-build-agent-images.md) |
| Add an agent integration | [Add a plugin](how-to-add-a-plugin.md) |

## System references

- [Architecture](architecture.md): components, process roles, and trust boundaries.
- [Requirements](requirements.md): product scope and implementation requirements.
- [Data model](data-model.md): tables, fields, relationships, and invariants.
- [Job lifecycle](job-lifecycle.md): admission, dependencies, attempts, results, and recovery.
- [Distributed execution](distributed-execution.md): worker protocol, leases, slots, and result delivery.
- [Kata runtime](runtime-kata.md): installation implementation and compatibility checks.
- [Design decisions](design-decisions.md): accepted choices and deferred proposals.
- [Validation results](validation-results.md): dated measurements and evidence limits.

## Documentation ownership

Keep development setup, tests, architecture, and requirements in this directory.
Keep installation configuration and user procedures directly in `docs/`.
Use component READMEs only to identify the component and link to its procedure.
Do not duplicate the same procedure in several files.
