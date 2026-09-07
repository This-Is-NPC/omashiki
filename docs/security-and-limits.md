# Security and limits

The house controls execution policy.
A client selects registered names and supplies an instruction with optional context.

## Access boundaries

| Location | Stored data |
| --- | --- |
| House | Operator account, queue, registry, provider API keys, identity keys, and results. |
| Worker | Local slots, Docker access, enrollment tokens, mirrors, and temporary attempt state. |
| Sandbox | Job workspace, declared tools, temporary claims, and private credential copies when configured. |
| Integration handler | Tracker authentication, event mapping, and its own callback credentials. |

Provider API keys for gateway access remain in the house.
Subscription credential files are a separate access method.
Those files exist on the execution machine and are copied for each attempt.
The worker does not receive the developer's house password or house database.

The GitHub identity broker keeps App keys and installation tokens in the house.
A sandbox receives only the job authorization needed to call the broker.

## Container policy

The runtime drops Linux capabilities and disables privilege escalation.
It uses a read-only root filesystem, bounded temporary storage, and resource limits.
Declared mounts and network settings remain part of the environment policy.
A host-network environment has different isolation properties from a restricted environment.

The sandbox does not receive the host Docker socket.
The worker controls Docker and is therefore a trusted execution component.
Do not treat worker enrollment as permission to run an untrusted worker operator.

## Output checks

Git finalization checks paths, likely secrets, output size, and worktree state.
A successful Git result identifies a committed branch with base and head revisions.
The machine publishes to the configured remote after validation.
The agent does not receive the canonical remote's push credentials.

File results use path validation and a digest-checked archive.
A `none` result contains completion metadata.
Cancellation cannot reverse an external action that already completed.

## Limits

| Item | Limit or policy |
| --- | --- |
| Encoded job payload | 1 MiB. |
| Atomic batch | 100 jobs. |
| Priority | Integer from `0` through `3`. |
| Concurrent containers | The execution machine's configured capacity. |
| CPU, memory, PIDs | The environment and machine resource settings. |
| Attempt duration | The environment's `timeout_ms`. |
| Git output | 100 MiB maximum change size. |
| Terminal webhook retries | 24-hour retry window. |
| Event and queue retention | Configured retention; the documented default is 30 days. |
| Git run branches | Default 30-day pruning horizon. Current successful task pointers have separate preservation rules. |

A shared worker has one local capacity limit across its houses.
Increasing that limit does not increase physical CPU, memory, or database capacity.

## Secret rotation

Changing `SECRET_KEY_BASE` invalidates existing API tokens.
Changing `OMASHIKI_CLOAK_KEY` can make encrypted data unreadable.
Keep the relevant key material when you back up persistent state.

See [known limitations](what-does-not-work.md) before you rely on an unverified integration or runtime property.
Implementation details belong in [the internal architecture](internal/architecture.md).
